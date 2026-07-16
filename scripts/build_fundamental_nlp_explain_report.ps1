param(
    [string]$DailyDir = "C:\ftshare_data\daily_intraday_summary\20260716_100619",
    [string]$MarketDir = "C:\ftshare_data\market_state_research\20260716_20260716_101206",
    [string]$TradeDate = "2026-07-16",
    [int]$MaxSymbols = 120,
    [int]$MaxNewsQueries = 60,
    [switch]$SkipNetwork
)

$ErrorActionPreference = "Stop"
$RunPy = "C:\Users\xhth\.codex\skills\ftshare-market-data\run.py"
$BaseUrl = "https://market.ft.tech/gateway"
$RunId = (Get-Date).ToString("yyyyMMdd_HHmmss")
$OutRoot = Join-Path "C:\ftshare_data\fundamental_nlp" ("{0}_{1}" -f ($TradeDate -replace "-", ""), $RunId)
$CacheRoot = Join-Path "C:\ftshare_data\fundamental_nlp\cache" ($TradeDate -replace "-", "")
New-Item -ItemType Directory -Force -Path $OutRoot, $CacheRoot | Out-Null

function To-Number($Value) {
    if ($null -eq $Value -or $Value -eq "") { return $null }
    $n = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $n
    }
    return $null
}

function Read-JsonFile([string]$Path) {
    if (Test-Path $Path) { return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    return $null
}

function Get-SixCode($Symbol) {
    if ($null -eq $Symbol) { return "" }
    $s = [string]$Symbol
    if ($s -match "^(\d{6})") { return $Matches[1] }
    return $s
}

function Convert-ToFtSymbol($Symbol) {
    $six = Get-SixCode $Symbol
    if ($Symbol -match "\.SH$") { return "$six.SH" }
    if ($Symbol -match "\.SZ$") { return "$six.SZ" }
    return [string]$Symbol
}

function Get-CachePath([string]$Name, [string[]]$SkillArgs) {
    $raw = ($Name + "|" + ($SkillArgs -join "|"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
    $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").Substring(0, 24).ToLowerInvariant()
    $prefix = $Name -replace "[^a-zA-Z0-9_.-]", "_"
    return Join-Path $CacheRoot ("{0}_{1}.json" -f $prefix, $hash)
}

function Convert-ArgsToQuery([string[]]$SkillArgs) {
    $pairs = @()
    for ($i = 0; $i -lt $SkillArgs.Count; $i += 2) {
        $key = ([string]$SkillArgs[$i]).TrimStart("-").Replace("-", "_")
        $value = if ($i + 1 -lt $SkillArgs.Count) { [string]$SkillArgs[$i + 1] } else { "" }
        if ($key) { $pairs += ("{0}={1}" -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString($value)) }
    }
    return ($pairs -join "&")
}

function Get-FtSkillPath([string]$Name) {
    switch ($Name) {
        "eastmoney-stock-valuation" { return "/api/v1/market/data/eastmoney-stock-valuation" }
        "major-contract-by-symbol" { return "/api/v1/market/data/corporate/contract/by-symbol" }
        "stock-unlock-by-stock" { return "/api/v1/market/data/unlock/stock-unlock" }
        "semantic-search-news" { return "/api/v1/market/data/semantic-search-news" }
        "stock-rank-eastmoney" { return "/api/v1/market/data/eastmoney-rank" }
        "stock-rank-xueqiu" { return "/api/v1/market/data/xueqiu-rank" }
        "stock-comment-index" { return "/api/v1/market/data/stock-comment/index" }
        default { return "" }
    }
}

function Invoke-FtSkillHttp([string]$Name, [string[]]$SkillArgs) {
    $path = Get-FtSkillPath $Name
    if (-not $path) { return $null }
    $query = Convert-ArgsToQuery -SkillArgs $SkillArgs
    $url = $BaseUrl + $path
    if ($query) { $url = $url + "?" + $query }
    return Invoke-RestMethod -Method Get -Uri $url -Headers @{ "X-Client-Name" = "ft-claw" } -TimeoutSec 60
}
function Invoke-FtSkill([string]$Name, [Parameter(ValueFromRemainingArguments=$true)][string[]]$SkillArgs) {
    $cache = Get-CachePath -Name $Name -SkillArgs $SkillArgs
    if (Test-Path $cache) {
        try { return Get-Content -Path $cache -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    }
    if ($SkipNetwork) { return $null }
    try {
        $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
        if ($pythonCmd) {
            $allArgs = @($RunPy, $Name) + $SkillArgs
            $text = & python @allArgs 2>&1
            $joined = ($text | Out-String).Trim()
        } else {
            $joined = (Invoke-FtSkillHttp -Name $Name -SkillArgs $SkillArgs) | ConvertTo-Json -Depth 20 -Compress
        }
        if (-not $joined) { return $null }
        Set-Content -Path $cache -Value $joined -Encoding UTF8
        return $joined | ConvertFrom-Json
    } catch {
        $err = [pscustomobject]@{ error = $_.Exception.Message; skill = $Name; args = $SkillArgs }
        $err | ConvertTo-Json -Depth 5 | Set-Content -Path $cache -Encoding UTF8
        return $null
    }
}

function Select-CandidatePool($Signals, $Sectors) {
    $picked = [ordered]@{}
    function Add-Rows($Rows) {
        foreach ($r in $Rows) {
            if ($picked.Count -ge $MaxSymbols) { break }
            $six = Get-SixCode $r.symbol
            if ($six -and -not $picked.Contains($six)) { $picked[$six] = $r }
        }
    }
    Add-Rows (@($Signals | Sort-Object @{ Expression = { To-Number $_.return_5m }; Descending = $true } | Select-Object -First 20))
    Add-Rows (@($Signals | Sort-Object @{ Expression = { To-Number $_.turnover_delta_5m }; Descending = $true } | Select-Object -First 20))
    Add-Rows (@($Signals | Sort-Object @{ Expression = { To-Number $_.resonance_score_5m }; Descending = $true } | Select-Object -First 20))
    Add-Rows (@($Signals | Sort-Object @{ Expression = { To-Number $_.risk_score_5m }; Descending = $true } | Select-Object -First 20))
    Add-Rows (@($Signals | Sort-Object @{ Expression = { To-Number $_.weighted_change_contribution }; Descending = $true } | Select-Object -First 20))
    Add-Rows (@($Signals | Sort-Object @{ Expression = { To-Number $_.change_rate }; Descending = $true } | Select-Object -First 20))
    foreach ($sec in @($Sectors | Sort-Object @{ Expression = { To-Number $_.sector_score }; Descending = $true } | Select-Object -First 10)) {
        Add-Rows (@($Signals | Where-Object { $_.sw_level1_name -eq $sec.sw_level1_name } | Sort-Object @{ Expression = { To-Number $_.composite_score }; Descending = $true } | Select-Object -First 3))
    }
    return $picked
}

function Get-ValuationRecords([string]$Date) {
    $records = @()
    for ($page = 1; $page -le 20; $page++) {
        $resp = Invoke-FtSkill "eastmoney-stock-valuation" "--start_date" $Date "--end_date" $Date "--page" "$page" "--page_size" "500"
        $batch = @($resp.data.records)
        if (-not $batch -or $batch.Count -eq 0) { break }
        $records += $batch
        if ($resp.data.pages -and $page -ge [int]$resp.data.pages) { break }
    }
    return $records
}

function Get-Percentile($Values, [double]$P) {
    $arr = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($arr.Count -eq 0) { return $null }
    $idx = [Math]::Min($arr.Count - 1, [Math]::Max(0, [int][Math]::Floor(($arr.Count - 1) * $P)))
    return [double]$arr[$idx]
}

function New-FundamentalRows($Signals, $Valuations) {
    $valMap = @{}
    foreach ($v in $Valuations) { if ($v.stock_code) { $valMap[[string]$v.stock_code] = $v } }
    $caps = @($Valuations | ForEach-Object { To-Number $_.total_market_cap })
    $capLow = Get-Percentile $caps 0.33
    $capHigh = Get-Percentile $caps 0.67
    foreach ($s in $Signals) {
        $six = Get-SixCode $s.symbol
        $v = $valMap[$six]
        $pe = To-Number $v.pe_ttm; $pb = To-Number $v.pb_mrq; $ps = To-Number $v.ps_ttm; $pcf = To-Number $v.pcf_ocf_ttm
        $cap = To-Number $v.total_market_cap; $freeCap = To-Number $v.notlimited_marketcap_a
        $valuationBucket = "缺失"
        if ($null -ne $pe -or $null -ne $pb) {
            if (($null -ne $pe -and $pe -gt 0 -and $pe -le 25) -and ($null -eq $pb -or $pb -le 3)) { $valuationBucket = "低估值" }
            elseif (($null -ne $pe -and ($pe -lt 0 -or $pe -gt 80)) -or ($null -ne $pb -and $pb -gt 8)) { $valuationBucket = "高估值" }
            else { $valuationBucket = "中性" }
        }
        $capBucket = "缺失"
        if ($null -ne $cap -and $null -ne $capLow -and $null -ne $capHigh) {
            if ($cap -ge $capHigh) { $capBucket = "大" } elseif ($cap -le $capLow) { $capBucket = "小" } else { $capBucket = "中" }
        }
        $flag = "缺失"; $score = $null
        if ($valuationBucket -ne "缺失") {
            $score = 0.0
            if ($valuationBucket -eq "低估值") { $score += 1.0 }
            if ($valuationBucket -eq "高估值") { $score -= 1.0 }
            if ($null -ne $pcf -and $pcf -gt 0) { $score += 0.5 }
            if ($null -ne $pcf -and $pcf -lt 0) { $score -= 0.5 }
            if ($score -ge 1) { $flag = "稳健" } elseif ($score -le -1) { $flag = "风险" } else { $flag = "中性" }
        }
        [pscustomobject]@{
            symbol = $s.symbol; stock_code = $six; component_name = $s.component_name; sw_level1_name = $s.sw_level1_name
            pe_ttm = $pe; pb_mrq = $pb; ps_ttm = $ps; pcf_ocf_ttm = $pcf; total_market_cap = $cap; notlimited_marketcap_a = $freeCap
            valuation_bucket = $valuationBucket; market_cap_bucket = $capBucket; fundamental_quality_flag = $flag; fundamental_score = $score
            data_status = if ($v) { "ok" } else { "missing" }
        }
    }
}

function Get-RecentItems($Records, [string[]]$DateFields, [int]$PastDays, [int]$FutureDays) {
    $start = ([datetime]$TradeDate).AddDays(-$PastDays)
    $end = ([datetime]$TradeDate).AddDays($FutureDays)
    $out = @()
    foreach ($r in @($Records)) {
        foreach ($f in $DateFields) {
            if ($r.PSObject.Properties.Name -contains $f -and $r.$f) {
                $dt = [datetime]::MinValue
                if ([datetime]::TryParse([string]$r.$f, [ref]$dt) -and $dt -ge $start -and $dt -le $end) { $out += $r; break }
            }
        }
    }
    return $out
}

function New-EventRows($Candidates) {
    foreach ($entry in $Candidates.GetEnumerator()) {
        $r = $entry.Value; $six = $entry.Key
        $contracts = Invoke-FtSkill "major-contract-by-symbol" "--symbol" $six "--page" "1" "--page_size" "50"
        $unlocks = Invoke-FtSkill "stock-unlock-by-stock" "--stock_code" $six "--page" "1" "--page_size" "50"
        $contractRecent = Get-RecentItems @($contracts.data.records) @("notice_date", "noticeDate", "公告日期", "publishDate", "publish_date") 180 0
        $unlockNear = Get-RecentItems @($unlocks.data.records) @("unlockDate") 30 30
        $unlockRatio = $null
        if ($unlockNear.Count -gt 0) { $unlockRatio = @($unlockNear | ForEach-Object { To-Number $_.totalRatio } | Sort-Object -Descending | Select-Object -First 1)[0] }
        $unlockRisk = "无"
        if ($null -ne $unlockRatio) {
            if ($unlockRatio -ge 0.05) { $unlockRisk = "高" } elseif ($unlockRatio -ge 0.01) { $unlockRisk = "中" } else { $unlockRisk = "低" }
        } elseif ($unlockNear.Count -gt 0) { $unlockRisk = "低" }
        $score = 0.0; $tags = @()
        if ($contractRecent.Count -gt 0) { $score += 1.0; $tags += "重大合同" }
        if ($unlockRisk -eq "高") { $score -= 1.0; $tags += "临近高比例解禁" }
        elseif ($unlockRisk -eq "中") { $score -= 0.5; $tags += "临近解禁" }
        [pscustomobject]@{
            symbol = $r.symbol; stock_code = $six; component_name = $r.component_name; sw_level1_name = $r.sw_level1_name
            has_recent_contract = ($contractRecent.Count -gt 0); recent_contract_count = $contractRecent.Count
            has_near_unlock = ($unlockNear.Count -gt 0); near_unlock_count = $unlockNear.Count; unlock_risk_level = $unlockRisk
            event_catalyst_score = $score; event_tags = (($tags | Select-Object -Unique) -join "|")
            data_status = if ($contracts -or $unlocks) { "ok" } else { "missing" }
        }
    }
}

function Get-NewsTags([string]$Text) {
    $topics = @()
    foreach ($pair in @(
        @("AI|人工智能|算力|大模型", "AI算力"),
        @("芯片|半导体|存储|晶圆", "半导体"),
        @("机器人|自动化|智能制造", "机器人"),
        @("创新药|医药|医疗|临床", "医药"),
        @("军工|卫星|低空|航天", "军工"),
        @("新能源|光伏|储能|电池", "新能源")
    )) { if ($Text -match $pair[0]) { $topics += $pair[1] } }
    return ($topics | Select-Object -Unique)
}

function Get-SentimentRule([string]$Text) {
    $pos = ($Text -match "中标|合同|订单|增长|预增|突破|回购|合作|扩产|创新高")
    $neg = ($Text -match "减持|解禁|亏损|处罚|立案|风险|下滑|诉讼|退市|问询")
    if ($pos -and -not $neg) { return "正面" }
    if ($neg -and -not $pos) { return "负面" }
    if ($pos -and $neg) { return "混合" }
    return "中性"
}

function New-NewsRows($Candidates, $SectorRows) {
    $rows = @()
    $queryCount = 0
    $start3 = ([datetime]$TradeDate).AddDays(-3).ToString("yyyy-MM-ddT00:00:00+08:00")
    $start15 = ([datetime]$TradeDate).AddDays(-15).ToString("yyyy-MM-ddT00:00:00+08:00")
    $end = ([datetime]$TradeDate).ToString("yyyy-MM-ddT23:59:59+08:00")
    foreach ($entry in $Candidates.GetEnumerator()) {
        if ($queryCount -ge $MaxNewsQueries) { break }
        $r = $entry.Value; $six = $entry.Key
        $query = [string]$r.component_name
        $resp15 = Invoke-FtSkill "semantic-search-news" "--query" $query "--limit" "5" "--year" "2026" "--start_time" $start15 "--end_time" $end
        $resp3 = Invoke-FtSkill "semantic-search-news" "--query" $query "--limit" "5" "--year" "2026" "--start_time" $start3 "--end_time" $end
        $queryCount++
        $items15 = @($resp15 | Where-Object { -not ($_.PSObject.Properties.Name -contains "error") })
        $items3 = @($resp3 | Where-Object { -not ($_.PSObject.Properties.Name -contains "error") })
        $text = (($items15 | ForEach-Object { "$($_.title) $($_.summary) $($_.content)" }) -join " ")
        $topics = Get-NewsTags $text
        $sentiment = Get-SentimentRule $text
        $topScore = @($items15 | ForEach-Object { To-Number $_.score } | Sort-Object -Descending | Select-Object -First 1)[0]
        $score = 0.0
        if ($items3.Count -gt 0) { $score += 0.6 }
        if ($items15.Count -gt 1) { $score += 0.4 }
        if ($sentiment -eq "正面") { $score += 0.5 } elseif ($sentiment -eq "负面") { $score -= 0.5 }
        if ($topics.Count -gt 0) { $score += 0.3 }
        $rows += [pscustomobject]@{
            symbol = $r.symbol; stock_code = $six; component_name = $r.component_name; sw_level1_name = $r.sw_level1_name
            news_count_3d = $items3.Count; news_count_15d = $items15.Count; top_news_score = $topScore
            matched_topics = ($topics -join "|"); sentiment_rule = $sentiment
            novelty_flag = ($items3.Count -gt 0 -and $items15.Count -le 2); news_catalyst_score = $score
            top_news_title = if ($items15.Count -gt 0) { [string]$items15[0].title } else { "" }
            data_status = if ($items15.Count -gt 0 -or $items3.Count -gt 0) { "ok" } else { "missing" }
        }
    }
    foreach ($sec in @($SectorRows | Sort-Object @{ Expression = { To-Number $_.sector_score }; Descending = $true } | Select-Object -First 5)) {
        if ($queryCount -ge $MaxNewsQueries) { break }
        $query = [string]$sec.sw_level1_name
        $resp = Invoke-FtSkill "semantic-search-news" "--query" $query "--limit" "5" "--year" "2026" "--start_time" $start15 "--end_time" $end
        $queryCount++
        $text = (($resp | ForEach-Object { "$($_.title) $($_.summary) $($_.content)" }) -join " ")
        $topics = Get-NewsTags $text
        $rows += [pscustomobject]@{
            symbol = ""; stock_code = ""; component_name = ""; sw_level1_name = $sec.sw_level1_name
            news_count_3d = ""; news_count_15d = @($resp).Count; top_news_score = @($resp | ForEach-Object { To-Number $_.score } | Sort-Object -Descending | Select-Object -First 1)[0]
            matched_topics = ($topics -join "|"); sentiment_rule = Get-SentimentRule $text
            novelty_flag = ""; news_catalyst_score = if (@($resp).Count -gt 0) { 0.4 } else { 0 }
            top_news_title = if (@($resp).Count -gt 0) { [string]@($resp)[0].title } else { "" }
            data_status = "sector_query"
        }
    }
    return $rows
}

function New-AttentionRows($Signals) {
    $maps = @{ hot = @{}; up = @{}; follow = @{}; tweet = @{}; deal = @{}; comment = @{} }
    foreach ($group in @("hot", "up")) {
        $resp = Invoke-FtSkill "stock-rank-eastmoney" "--rank-group" $group "--market" "A" "--trade-date" $TradeDate
        if (@($resp.data.items).Count -eq 0) { $resp = Invoke-FtSkill "stock-rank-eastmoney" "--rank-group" $group "--market" "A" }
        foreach ($it in @($resp.data.items)) { if ($it.normalized_symbol) { $maps[$group][(Get-SixCode $it.normalized_symbol)] = $it } }
    }
    foreach ($group in @("follow", "tweet", "deal")) {
        $resp = Invoke-FtSkill "stock-rank-xueqiu" "--rank-group" $group "--period" "7d" "--trade-date" $TradeDate "--page" "1" "--page-size" "100"
        if (@($resp.data.items).Count -eq 0) { $resp = Invoke-FtSkill "stock-rank-xueqiu" "--rank-group" $group "--period" "7d" "--page" "1" "--page-size" "100" }
        foreach ($it in @($resp.data.items)) { if ($it.normalized_symbol) { $maps[$group][(Get-SixCode $it.normalized_symbol)] = $it } }
    }
    $comment = Invoke-FtSkill "stock-comment-index"
    foreach ($it in @($comment.data.items)) { if ($it.security_code) { $maps.comment[[string]$it.security_code] = $it } }

    foreach ($s in $Signals) {
        $six = Get-SixCode $s.symbol
        $rankScore = 0.0; $rankHits = 0
        foreach ($group in @("hot", "up", "follow", "tweet", "deal")) {
            $it = $maps[$group][$six]
            if ($it) {
                $rank = To-Number $it.rank_no
                if ($null -ne $rank) { $rankScore += [Math]::Max(0, 1 - ($rank / 100)); $rankHits++ }
            }
        }
        $c = $maps.comment[$six]
        $commentScore = To-Number $c.total_score
        $focusScore = To-Number $c.focus
        $attentionScore = if ($rankHits -gt 0) { $rankScore / $rankHits } else { $null }
        if ($null -ne $focusScore) {
            $baseAttention = 0
            if ($null -ne $attentionScore) { $baseAttention = $attentionScore }
            $attentionScore = ($baseAttention + [Math]::Min(1, $focusScore / 100)) / 2
        }
        $bucket = "缺失"
        if ($null -ne $attentionScore) {
            if ($attentionScore -ge 0.66) { $bucket = "高" } elseif ($attentionScore -ge 0.33) { $bucket = "中" } else { $bucket = "低" }
        }
        [pscustomobject]@{
            symbol = $s.symbol; stock_code = $six; component_name = $s.component_name; sw_level1_name = $s.sw_level1_name
            attention_rank_score = $attentionScore; comment_score = $commentScore; focus_score = $focusScore
            attention_bucket = $bucket; attention_catalyst_flag = ($bucket -eq "高")
            eastmoney_hot_rank = (To-Number $maps.hot[$six].rank_no); eastmoney_up_rank = (To-Number $maps.up[$six].rank_no)
            xueqiu_follow_rank = (To-Number $maps.follow[$six].rank_no); xueqiu_tweet_rank = (To-Number $maps.tweet[$six].rank_no); xueqiu_deal_rank = (To-Number $maps.deal[$six].rank_no)
            data_status = if ($bucket -eq "缺失") { "missing" } else { "ok" }
        }
    }
}

function Get-Map($Rows) {
    $m = @{}
    foreach ($r in @($Rows)) { if ($r.stock_code) { $m[[string]$r.stock_code] = $r } }
    return $m
}

function New-ExplainDataset($Signals, $FundRows, $EventRows, $NewsRows, $AttentionRows) {
    $fm = Get-Map $FundRows; $em = Get-Map $EventRows; $nm = Get-Map (@($NewsRows | Where-Object { $_.stock_code })); $am = Get-Map $AttentionRows
    foreach ($s in $Signals) {
        $six = Get-SixCode $s.symbol
        $f = $fm[$six]; $e = $em[$six]; $n = $nm[$six]; $a = $am[$six]
        $parts = @()
        $fs = To-Number $f.fundamental_score; $es = To-Number $e.event_catalyst_score; $ns = To-Number $n.news_catalyst_score; $as = To-Number $a.attention_rank_score
        $score = 0.0; $available = 0
        foreach ($v in @($fs, $es, $ns, $as)) { if ($null -ne $v) { $score += $v; $available++ } }
        if ($f.fundamental_quality_flag -eq "稳健") { $parts += "基本面支撑" }
        if ($e.event_catalyst_score -gt 0 -or $n.news_catalyst_score -gt 0.8) { $parts += "事件催化" }
        if ($a.attention_bucket -eq "高") { $parts += "关注度驱动" }
        if ($e.unlock_risk_level -in @("中", "高") -or $n.sentiment_rule -eq "负面") { $parts += "风险解释" }
        $label = if ($parts.Count -gt 0) { ($parts | Select-Object -Unique) -join "+" } else { if ($available -eq 0) { "数据不足" } else { "暂无解释" } }
        $conf = if ($available -ge 3) { "高" } elseif ($available -ge 2) { "中" } else { "低" }
        [pscustomobject]@{
            snapshot_time = $s.snapshot_time; symbol = $s.symbol; stock_code = $six; component_name = $s.component_name; sw_level1_name = $s.sw_level1_name
            close = To-Number $s.close; change_rate = To-Number $s.change_rate; return_5m = To-Number $s.return_5m; turnover_delta_5m = To-Number $s.turnover_delta_5m
            resonance_score_5m = To-Number $s.resonance_score_5m; risk_score_5m = To-Number $s.risk_score_5m; composite_score = To-Number $s.composite_score
            valuation_bucket = $f.valuation_bucket; market_cap_bucket = $f.market_cap_bucket; fundamental_quality_flag = $f.fundamental_quality_flag; fundamental_score = $fs
            has_recent_contract = $e.has_recent_contract; has_near_unlock = $e.has_near_unlock; unlock_risk_level = $e.unlock_risk_level; event_catalyst_score = $es; event_tags = $e.event_tags
            news_count_3d = $n.news_count_3d; news_count_15d = $n.news_count_15d; matched_topics = $n.matched_topics; sentiment_rule = $n.sentiment_rule; novelty_flag = $n.novelty_flag; news_catalyst_score = $ns
            attention_rank_score = $as; comment_score = $a.comment_score; focus_score = $a.focus_score; attention_bucket = $a.attention_bucket; attention_catalyst_flag = $a.attention_catalyst_flag
            explain_score = if ($available -gt 0) { $score } else { $null }; explain_label = $label; explain_confidence = $conf
        }
    }
}

function Count-Where($Rows, [scriptblock]$Block) { return @($Rows | Where-Object $Block).Count }

function Write-ReportHtml($Dataset, $SectorNews, $Summary, [string]$Path) {
    $top = @($Dataset | Sort-Object @{ Expression = { To-Number $_.explain_score }; Descending = $true } | Select-Object -First 60)
    $sector = @($Dataset | Group-Object sw_level1_name | ForEach-Object {
        [pscustomobject]@{
            sector = $_.Name
            count = $_.Count
            avg_explain = (@($_.Group | ForEach-Object { To-Number $_.explain_score } | Where-Object { $null -ne $_ } | Measure-Object -Average).Average)
            event_count = Count-Where $_.Group { $_.event_catalyst_score -gt 0 }
            news_count = Count-Where $_.Group { $_.news_catalyst_score -gt 0 }
            attention_count = Count-Where $_.Group { $_.attention_bucket -eq "高" }
        }
    } | Sort-Object avg_explain -Descending)
    $payload = [pscustomobject]@{ summary = $Summary; top = $top; sector = $sector; sector_news = $SectorNews }
    $json = [System.Web.HttpUtility]::JavaScriptStringEncode(($payload | ConvertTo-Json -Depth 8 -Compress))
    $html = @'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>中证1000盘中异动解释研究</title>
<style>body{margin:0;background:#f7f8fa;color:#1f2937;font-family:"Microsoft YaHei UI","Microsoft YaHei",Arial,sans-serif;font-size:14px}header{padding:22px 28px;background:#fff;border-bottom:1px solid #d9dee7}main{max-width:1380px;margin:0 auto;padding:22px 28px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:12px}.card,.chart{background:#fff;border:1px solid #d9dee7;border-radius:8px;padding:14px}.label{color:#667085;font-size:12px}.value{font-size:24px;font-weight:600;margin-top:6px}.split{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-top:16px}table{width:100%;border-collapse:collapse;background:#fff;margin-top:16px}th,td{border-bottom:1px solid #d9dee7;padding:8px;text-align:right;white-space:nowrap}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2),th:nth-child(3),td:nth-child(3){text-align:left}th{color:#667085;background:#f2f4f7}.wide{overflow:auto}.bar{height:12px;background:#eef1f5;border-radius:999px;overflow:hidden}.fill{height:100%;background:#2563eb;border-radius:999px}.row{display:grid;grid-template-columns:120px 1fr 70px;gap:8px;align-items:center;margin:8px 0}.note{color:#667085;line-height:1.7}.pos{color:#c2410c}.neg{color:#047857}@media(max-width:900px){.split{grid-template-columns:1fr}header,main{padding-left:14px;padding-right:14px}}</style></head>
<body><header><h1>中证1000盘中异动解释研究</h1><div class="note">基本面质量 + 文本事件催化 + 市场关注度。研究解释，不构成投资建议。</div></header><main id="app"></main>
<script>
const DATA=JSON.parse("__DATA_JSON__");const fmt=v=>v==null?'--':Number(v).toLocaleString('zh-CN',{maximumFractionDigits:2});const pct=v=>v==null?'--':(Number(v)*100).toFixed(2)+'%';const esc=s=>String(s??'--').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));const cls=v=>v>0?'pos':v<0?'neg':'';function stat(a,b,c){return `<div class=card><div class=label>\${a}</div><div class=value>\${b}</div><div class=note>\${c||''}</div></div>`}function bars(items,key){let max=Math.max(1,...items.map(x=>Math.abs(x[key]||0)));return items.slice(0,16).map(x=>`<div class=row><div>\${esc(x.sector)}</div><div class=bar><div class=fill style="width:\${Math.max(2,Math.abs(x[key]||0)/max*100)}%"></div></div><div>\${fmt(x[key])}</div></div>`).join('')}function table(rows){return `<div class=wide><table><thead><tr><th>名称</th><th>代码</th><th>行业</th><th>解释分</th><th>标签</th><th>置信度</th><th>主题</th><th>关注度</th></tr></thead><tbody>\${rows.map(r=>`<tr><td>\${esc(r.component_name)}</td><td>\${esc(r.symbol)}</td><td>\${esc(r.sw_level1_name)}</td><td class="\${cls(r.explain_score)}">\${fmt(r.explain_score)}</td><td>\${esc(r.explain_label)}</td><td>\${esc(r.explain_confidence)}</td><td>\${esc(r.matched_topics)}</td><td>\${esc(r.attention_bucket)}</td></tr>`).join('')}</tbody></table></div>`}let s=DATA.summary;document.getElementById('app').innerHTML=`<div class=grid>\${stat('样本数',s.input_rows,'保留盘中输入主键')}\${stat('异动样本池',s.candidate_count,'事件/新闻定向查询')}\${stat('基本面覆盖',pct(s.fundamental_coverage),'估值字段可用比例')}\${stat('事件覆盖',pct(s.event_coverage),'重大合同/解禁查询')}\${stat('新闻覆盖',pct(s.news_coverage),'最近半个月新闻')}\${stat('关注度覆盖',pct(s.attention_coverage),'榜单/千股千评映射')}</div><div class=split><div class=chart><h2>行业解释强度</h2>\${bars(DATA.sector,'avg_explain')}</div><div class=chart><h2>解释来源</h2>\${stat('基本面支撑',s.fundamental_support_count,'稳健质量标签')}\${stat('事件催化',s.event_catalyst_count,'合同/新闻正向催化')}\${stat('关注度驱动',s.attention_driven_count,'热度榜或关注指数')}</div></div><h2>解释样本 Top</h2>\${table(DATA.top)}<p class=note>新闻语义搜索仅覆盖当年最近半个月；缺失代表接口未返回或未查询，不代表没有事件。</p>`;
</script></main></body></html>
'@
    $html = $html.Replace("__DATA_JSON__", $json)
    Set-Content -Path $Path -Value $html -Encoding UTF8
}

$signalsPath = Join-Path $DailyDir "latest_signals.csv"
$sectorsPath = Join-Path $DailyDir "sector_rotation.csv"
$qualityPath = Join-Path $DailyDir "data_quality.json"
$Signals = Import-Csv -Path $signalsPath -Encoding UTF8
$Sectors = Import-Csv -Path $sectorsPath -Encoding UTF8
$Quality = Read-JsonFile $qualityPath

$Candidates = Select-CandidatePool $Signals $Sectors
$valuationDates = @($TradeDate, ([datetime]$TradeDate).AddDays(-1).ToString("yyyy-MM-dd"), ([datetime]$TradeDate).AddDays(-2).ToString("yyyy-MM-dd"))
$Valuations = @(); $valuationDateUsed = ""
foreach ($d in $valuationDates) {
    $Valuations = @(Get-ValuationRecords $d)
    if ($Valuations.Count -gt 0) { $valuationDateUsed = $d; break }
}

$FundRows = @(New-FundamentalRows $Signals $Valuations)
$EventRows = @(New-EventRows $Candidates)
$NewsRows = @(New-NewsRows $Candidates $Sectors)
$AttentionRows = @(New-AttentionRows $Signals)
$Dataset = @(New-ExplainDataset $Signals $FundRows $EventRows $NewsRows $AttentionRows)

$fundPath = Join-Path $OutRoot "csi1000_fundamental_features.csv"
$eventPath = Join-Path $OutRoot "csi1000_event_features.csv"
$newsPath = Join-Path $OutRoot "csi1000_news_features.csv"
$attentionPath = Join-Path $OutRoot "csi1000_attention_features.csv"
$datasetPath = Join-Path $OutRoot "intraday_explain_dataset.csv"
$summaryPath = Join-Path $OutRoot "fundamental_nlp_summary.json"
$htmlPath = Join-Path $OutRoot "fundamental_nlp_report.html"

$FundRows | Export-Csv -Path $fundPath -NoTypeInformation -Encoding UTF8
$EventRows | Export-Csv -Path $eventPath -NoTypeInformation -Encoding UTF8
$NewsRows | Export-Csv -Path $newsPath -NoTypeInformation -Encoding UTF8
$AttentionRows | Export-Csv -Path $attentionPath -NoTypeInformation -Encoding UTF8
$Dataset | Export-Csv -Path $datasetPath -NoTypeInformation -Encoding UTF8

$summary = [pscustomobject]@{
    output_dir = $OutRoot; trade_date = $TradeDate; generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    daily_dir = $DailyDir; market_dir = $MarketDir; input_rows = $Signals.Count; candidate_count = $Candidates.Count
    data_quality = $Quality; valuation_date_used = $valuationDateUsed
    fundamental_coverage = if ($Signals.Count) { (Count-Where $FundRows { $_.data_status -eq "ok" }) / $Signals.Count } else { 0 }
    event_coverage = if ($Candidates.Count) { (Count-Where $EventRows { $_.data_status -eq "ok" }) / $Candidates.Count } else { 0 }
    news_coverage = if ($Candidates.Count) { (Count-Where $NewsRows { $_.stock_code -and $_.data_status -eq "ok" }) / $Candidates.Count } else { 0 }
    attention_coverage = if ($Signals.Count) { (Count-Where $AttentionRows { $_.data_status -eq "ok" }) / $Signals.Count } else { 0 }
    fundamental_support_count = Count-Where $Dataset { $_.fundamental_quality_flag -eq "稳健" }
    event_catalyst_count = Count-Where $Dataset { $_.event_catalyst_score -gt 0 -or $_.news_catalyst_score -gt 0.8 }
    attention_driven_count = Count-Where $Dataset { $_.attention_bucket -eq "高" }
    risk_explain_count = Count-Where $Dataset { $_.explain_label -match "风险解释" }
    files = [pscustomobject]@{
        csi1000_fundamental_features = $fundPath; csi1000_event_features = $eventPath; csi1000_news_features = $newsPath
        csi1000_attention_features = $attentionPath; intraday_explain_dataset = $datasetPath; report = $htmlPath
    }
    notes = @("研究解释，不构成投资建议", "新闻语义搜索仅覆盖当年最近半个月", "事件和新闻优先查询异动样本池")
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8
Write-ReportHtml $Dataset @($NewsRows | Where-Object { -not $_.stock_code }) $summary $htmlPath

[pscustomobject]@{ output_dir = $OutRoot; summary_json = $summaryPath; report_html = $htmlPath; dataset_csv = $datasetPath } | ConvertTo-Json -Depth 4











