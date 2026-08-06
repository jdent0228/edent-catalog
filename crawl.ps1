# 이덴트(edent.co.kr) 상품 카탈로그 크롤러
# 사용법(로컬):  powershell -ExecutionPolicy Bypass -File crawl.ps1
#   자격증명은 secret.local.ps1(git 제외) 또는 환경변수 EDENT_ID / EDENT_PW 로 주입.
# 결과:  같은 폴더의 data.js / data.json 갱신
#
# 수집: 카테고리 트리(program/show_cate_all_make.php)에서 소분류(cate3) + 중분류(cate2)
#       버킷을 모두 순회, 목록 페이지(shop_list.php)만 요청하여 pd_idx로 dedup.
#       로그인 세션이면 회원가까지 수집(비로그인은 정가만).

param(
  [string]$Id = $env:EDENT_ID,
  [string]$Pw = $env:EDENT_PW,
  [int]$DelayMs = 1000,          # Crawl-delay 1초 준수
  [int]$MaxBuckets = 0,          # 0=전체, >0이면 테스트용 제한
  [switch]$Details,              # 상세페이지 크롤로 규격(변형) 그룹 수집
  [int]$DetailsMax = 0           # 0=전체, >0이면 상세 방문 수 제한(테스트)
)

$ErrorActionPreference = 'Stop'
$Base = 'https://www.edent.co.kr'
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

# ---- 로컬 자격증명 파일 (git 제외) ----
$secretFile = Join-Path $PSScriptRoot 'secret.local.ps1'
if ((-not $Id -or -not $Pw) -and (Test-Path $secretFile)) {
  . $secretFile
  if (-not $Id) { $Id = $env:EDENT_ID }
  if (-not $Pw) { $Pw = $env:EDENT_PW }
}

$script:session = $null

function Get-Html([string]$url) {
  $r = Invoke-WebRequest -Uri $url -WebSession $script:session -UserAgent $ua -UseBasicParsing -TimeoutSec 40
  $bytes = $r.RawContentStream.ToArray()
  return [System.Text.Encoding]::UTF8.GetString($bytes)   # UTF-8 강제(한글 깨짐 방지)
}
function Dec([string]$s) { [System.Net.WebUtility]::HtmlDecode($s).Trim() }
function ToInt($s) { if ($s) { [int]((($s) -replace '[^\d]', '')) } else { $null } }

# ================= 1. 세션 + 로그인 =================
Invoke-WebRequest -Uri "$Base/member/login.php" -UserAgent $ua -SessionVariable session -UseBasicParsing -TimeoutSec 40 | Out-Null
$script:session = $session
$loggedIn = $false
if ($Id -and $Pw) {
  try {
    $body = @{ id = $Id; pw = $Pw; save_id = '0'; backurl = '/index.php' }
    Invoke-WebRequest -Uri "$Base/member/login_process.php" -Method Post -Body $body `
      -WebSession $script:session -UserAgent $ua -UseBasicParsing -TimeoutSec 40 | Out-Null
    $chk = Get-Html "$Base/index.php"
    if ($chk -match 'logout|로그아웃|MYPAGE|마이페이지') { $loggedIn = $true }
  } catch { Write-Warning "로그인 실패: $($_.Exception.Message)" }
}
Write-Host ("로그인 상태: {0}" -f $(if ($loggedIn) { '성공 → 회원가 수집' } else { '미로그인 → 정가만 수집' }))

# ================= 2. 카테고리 트리 파싱 =================
# <span class="title">대분류</span> ... <span class="blueTitle">중분류</span> ... <a ...cate3=..>소분류</a>
$tree = Get-Html "$Base/program/show_cate_all_make.php"

$tokens = [regex]::Matches($tree,
  '(?s)class="title">(?<t>[^<]+)<|class="blueTitle">(?<b>[^<]+)<|shop_list\.php\?cate1=(?<c1>\d+)&cate2=(?<c2>\d+)&cate3=(?<c3>\d+)"[^>]*>(?<n>[^<]+)<')

$leaves = [System.Collections.Generic.List[object]]::new()
$c1Name = @{}; $c2Name = @{}
$curT = ''; $curB = ''
foreach ($m in $tokens) {
  if ($m.Groups['t'].Success)      { $curT = Dec $m.Groups['t'].Value }
  elseif ($m.Groups['b'].Success)  { $curB = Dec $m.Groups['b'].Value }
  elseif ($m.Groups['c3'].Success) {
    $a = $m.Groups['c1'].Value; $b = $m.Groups['c2'].Value; $d = $m.Groups['c3'].Value
    if (-not $c1Name.ContainsKey($a)) { $c1Name[$a] = $curT }
    $c2Name["$a-$b"] = $curB
    $leaves.Add([pscustomobject]@{ c1 = $a; c2 = $b; c3 = $d; c1n = $curT; c2n = $curB; c3n = (Dec $m.Groups['n'].Value) })
  }
}

# 버킷 = 소분류(cate3) 전부 + 중분류(cate2) 전부  (부모·자식 상호 비포함 → 합집합 필요)
$buckets = [System.Collections.Generic.List[object]]::new()
foreach ($lf in $leaves) {
  $buckets.Add([pscustomobject]@{
    url  = "$Base/shop/shop_list.php?cate1=$($lf.c1)&cate2=$($lf.c2)&cate3=$($lf.c3)"
    c1n  = $lf.c1n; c2n = $lf.c2n; c3n = $lf.c3n; depth = 3
  })
}
$c2seen = @{}
foreach ($lf in $leaves) {
  $k = "$($lf.c1)-$($lf.c2)"
  if ($c2seen.ContainsKey($k)) { continue }; $c2seen[$k] = 1
  $buckets.Add([pscustomobject]@{
    url  = "$Base/shop/shop_list.php?cate1=$($lf.c1)&cate2=$($lf.c2)"
    c1n  = $lf.c1n; c2n = $lf.c2n; c3n = ''; depth = 2
  })
}
if ($MaxBuckets -gt 0 -and $buckets.Count -gt $MaxBuckets) {
  $buckets = $buckets[0..($MaxBuckets - 1)]
}
Write-Host ("카테고리: 대 $($c1Name.Count) / 중 $($c2seen.Count) / 소 $($leaves.Count)  → 버킷 $($buckets.Count)개")

# ================= 3. 상품 파싱 =================
function Parse-Products([string]$html) {
  # 목록에는 두 레이아웃이 섞여 있음(추천 카드 / 메인 그리드 행). 둘 다 상품 단위로
  # "실구매 가격<br> ... <b>N@금액원</b>" 으로 끝나므로 이를 앵커로 상품을 분리한다.
  # 이름링크 → (다음 상품 링크 전까지) → 실구매가 볼드금액.  (추천/하단 링크는 실구매가 없어 자동 제외)
  $pat = '(?s)item\.php\?pd_idx=(\d+)[^"]*">([^<]+)</a>((?:(?!item\.php\?pd_idx).){0,1800}?)실구매\s*가격\s*<br>\s*<span[^>]*>\s*<b>\s*\d*@\s*([\d,]+)\s*원'
  $ms = [regex]::Matches($html, $pat)
  # 상품코드: 메인그리드 행 첫 셀(<tr bgcolor="#FFFFFF"><td ...>0392-1962<p>)에 위치 → 위치 사전 스캔
  $codePos = [regex]::Matches($html, '<tr bgcolor="#FFFFFF">\s*<td[^>]*>\s*(\d{2,6}-\d{2,6})\s*<') |
    ForEach-Object { [pscustomobject]@{ idx = $_.Index; code = $_.Groups[1].Value } }
  $seen = @{}; $out = [System.Collections.Generic.List[object]]::new()
  foreach ($m in $ms) {
    $pdid = $m.Groups[1].Value
    $nm  = Dec $m.Groups[2].Value
    $mid = $m.Groups[3].Value
    $pReal = ToInt $m.Groups[4].Value

    # 회사/제조국 분리:
    #  - 메인그리드: 이름 뒤 "<br>[회사]"
    #  - 추천카드: skyblue 뱃지 (회사명 또는 '국산' 같은 제조국이 섞여 들어옴 → 국가명이면 country로)
    $company = ''; $country = ''
    $COUNTRY_RX = '^(국산|수입|한국|중국|일본|독일|미국|스위스|프랑스|영국|대만|파키스탄|이태리|이탈리아|이스라엘|인도|브라질|캐나다|스웨덴|덴마크|핀란드|호주|러시아|스페인|폴란드|체코|터키|베트남|태국)$'
    if ($mid -match '^\s*<br>\s*\[([^\]]+)\]') { $company = Dec $Matches[1] }
    elseif ($mid -match 'class="skyblue">([^<]+)<') {
      $b = Dec $Matches[1]
      if ($b -match $COUNTRY_RX) { $country = $b } else { $company = $b }
    }

    # 포장단위 (메인그리드: "5ea/pkg")
    $pkgL = ''
    if ($mid -match '>\s*([0-9][^<>]{0,14}?/\s*pkg)') { $pkgL = ($Matches[1] -replace '\s+', '') }

    # 규격: 이름~가격 사이 텍스트형 <span class="impact">규격</span>.
    # 즉시할인금액(Z_icon 뒤 "-0원" 등)을 규격으로 오인하지 않도록 Z_icon 이전 구간만 검색.
    $spec = ''
    $before = $mid
    $zi = $mid.IndexOf('Z_icon')
    if ($zi -ge 0) { $before = $mid.Substring(0, $zi) }
    $sm = [regex]::Match($before, '<span class="impact">([^<]+)</span>')
    if ($sm.Success) {
      $s = (Dec ($sm.Groups[1].Value -replace '&nbsp;', ' '))
      if ($s -and $s -notmatch '^-?[\d,]+\s*원?$') { $spec = $s }
    }

    # 정가: 첫 @금액원
    $pList = $null
    if ($mid -match '@\s*([\d,]+)\s*원') { $pList = ToInt $Matches[1] }
    # 회원가: 첫 @금액원 다음 줄의 @(…로그인 | 금액원). 로그인 세션이면 금액이 채워짐.
    $pMember = $null
    $mm = [regex]::Match($mid, '@\s*[\d,]+\s*원\s*<br>\s*\d*@\s*(?:(?:특가)?로그인|([\d,]+)\s*원)')
    if ($mm.Success -and $mm.Groups[1].Value) { $pMember = ToInt $mm.Groups[1].Value }

    # 목록 상품명은 "이름 + 규격"이 이어붙은 형태 → 이름 끝이 규격과 겹치면 잘라냄
    # (단, 이름 전체가 규격과 동일한 상품은 그대로 둠 — 이름이 비어버리는 사고 방지)
    if ($spec) {
      $spT = $spec.Trim()
      if ($spT -and $nm.TrimEnd().EndsWith($spT) -and $nm.TrimEnd().Length -gt $spT.Length) {
        $nm = $nm.TrimEnd().Substring(0, $nm.TrimEnd().Length - $spT.Length).Trim()
      }
    }

    # 규격보기 버튼 = 규격그룹 보유 (목록에 노출되는 확실한 신호)
    $hasGroup = [bool]($mid -match 'show_group_div\(')

    # 상품코드: 이름 링크 직전(3000자 이내)의 마지막 행시작 코드
    $code = ''
    foreach ($cp in $codePos) {
      if ($cp.idx -lt $m.Index -and ($m.Index - $cp.idx) -lt 3000) { $code = $cp.code }
      elseif ($cp.idx -ge $m.Index) { break }
    }

    if ($seen.ContainsKey($pdid)) {
      # 같은 페이지 중복(추천카드+메인그리드): 필드 병합 — 메인그리드(코드 보유) 데이터 우선
      $ex = $out[$seen[$pdid]]
      if ($hasGroup) { $ex.hasGroup = $true }
      if (-not $ex.code -and $code) {
        $ex.code = $code
        if ($nm) { $ex.name = $nm }          # 메인그리드 이름이 정본
      }
      if (-not $ex.spec -and $spec) { $ex.spec = $spec }
      if (-not $ex.company -and $company) { $ex.company = $company }
      if (-not $ex.country -and $country) { $ex.country = $country }
      if (-not $ex.pkg -and $pkgL) { $ex.pkg = $pkgL }
      if ($null -eq $ex.priceList -and $null -ne $pList) { $ex.priceList = $pList }
      if ($null -eq $ex.priceMember -and $null -ne $pMember) { $ex.priceMember = $pMember }
      if ($null -eq $ex.priceReal -and $null -ne $pReal) { $ex.priceReal = $pReal }
      # 병합 후 이름 끝 규격 중복 제거
      if ($ex.spec) {
        $spX = $ex.spec.Trim()
        if ($spX -and $ex.name.TrimEnd().EndsWith($spX) -and $ex.name.TrimEnd().Length -gt $spX.Length) {
          $ex.name = $ex.name.TrimEnd().Substring(0, $ex.name.TrimEnd().Length - $spX.Length).Trim()
        }
      }
      continue
    }
    $seen[$pdid] = $out.Count
    $out.Add([pscustomobject]@{
      id = $pdid; name = $nm; company = $company; country = $country; spec = $spec
      priceList = $pList; priceMember = $pMember; priceReal = $pReal
      hasGroup = $hasGroup; code = $code; pkg = $pkgL
    })
  }
  , $out
}

function Get-MaxPage([string]$html) {
  $p = [regex]::Matches($html, 'page=(\d+)&') | ForEach-Object { [int]$_.Groups[1].Value }
  if ($p) { ($p | Measure-Object -Maximum).Maximum } else { 1 }
}

# ================= 4. 순회 =================
# 이전 크롤 결과 로드 (그룹정보 gid 승계 + 목록에 없는 변형상품 유지용)
$old = @{}
$oldFile = Join-Path $PSScriptRoot 'data-edent.json'
if (-not (Test-Path $oldFile)) { $oldFile = Join-Path $PSScriptRoot 'data.json' }   # 구버전 호환
if (Test-Path $oldFile) {
  try {
    $oldData = Get-Content $oldFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($o in $oldData.items) { $old[$o.id] = $o }
    Write-Host "이전 데이터 로드: $($old.Count)건"
  } catch { Write-Warning "이전 data.json 로드 실패: $($_.Exception.Message)" }
}

$items = @{}   # id -> record
$reqCount = 0
$bi = 0
foreach ($bk in $buckets) {
  $bi++
  $page = 1; $maxp = 1
  while ($page -le $maxp) {
    $u = if ($page -eq 1) { $bk.url } else { "$($bk.url)&page=$page" }
    try { $html = Get-Html $u } catch { Write-Warning "요청 실패 $u : $($_.Exception.Message)"; break }
    $reqCount++
    if ($page -eq 1) { $maxp = Get-MaxPage $html }

    foreach ($p in (Parse-Products $html)) {
      $catPath = @($bk.c1n, $bk.c2n, $bk.c3n | Where-Object { $_ }) -join ' > '
      if ($items.ContainsKey($p.id)) {
        $rec = $items[$p.id]
        if ($rec.cats -notcontains $catPath) { $rec.cats += $catPath }
        # 더 구체적인(소분류) 카테고리를 대표값으로
        if ($bk.depth -eq 3 -and -not $rec.catLeaf) { $rec.catLeaf = $catPath; $rec.cat1 = $bk.c1n; $rec.cat2 = $bk.c2n }
        if ($null -eq $rec.priceList)   { $rec.priceList = $p.priceList }
        if ($null -eq $rec.priceMember) { $rec.priceMember = $p.priceMember }
        if ($null -eq $rec.priceReal)   { $rec.priceReal = $p.priceReal }
        if (-not $rec.company) { $rec.company = $p.company }
        if (-not $rec.country) { $rec.country = $p.country }
        if (-not $rec.spec) { $rec.spec = $p.spec }
        if (-not $rec.pkg -and $p.pkg) { $rec.pkg = $p.pkg }
        if ($p.hasGroup) { $rec.hasGroup = $true }
        if (-not $rec.code -and $p.code) { $rec.code = $p.code }
      } else {
        $items[$p.id] = [pscustomobject]@{
          id = $p.id; name = $p.name; company = $p.company; country = $p.country; spec = $p.spec
          priceList = $p.priceList; priceMember = $p.priceMember; priceReal = $p.priceReal
          cat1 = $bk.c1n; cat2 = $bk.c2n
          catLeaf = $(if ($bk.depth -eq 3) { $catPath } else { '' })
          cats = @($catPath)
          img = "$Base/data/product/img_m1_$($p.id)"
          url = "$Base/shop/item.php?pd_idx=$($p.id)"
          pkg = $p.pkg; gid = ''; hasGroup = $p.hasGroup; code = $p.code
        }
      }
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    $page++
  }
  if ($bi % 25 -eq 0) { Write-Host ("  진행 $bi/$($buckets.Count) 버킷 · 요청 $reqCount · 상품 $($items.Count)") }
}

# ================= 4.4 안전장치 (크롤 실패 시 좋은 데이터 덮어쓰기 방지) =================
# 클라우드(Actions) 등에서 접근이 막혀 목록 크롤이 사실상 실패하는 사고가 있었음.
# 신선 수집분이 비정상적으로 적으면 파일을 쓰지 않고 실패 종료한다.
$freshCount = $items.Count
$minExpected = 3000
if ($old.Count -gt 0) {
  # 직전 대비 60% 미만이면 이상으로 간주 (변형상품 승계분은 제외한 목록 기준 비교)
  $oldListing = @($old.Values | Where-Object {
    -not $_.PSObject.Properties['gid'] -or -not $_.gid -or $_.gid -eq 'solo' -or $_.gid -eq $_.id
  }).Count
  if ($oldListing -gt 1000) { $minExpected = [int]($oldListing * 0.6) }
}
if ($freshCount -lt $minExpected) {
  throw "목록 크롤 실패 의심: 신선 수집 $freshCount개 (기대 최소 $minExpected개). 로그인=$loggedIn. 데이터를 쓰지 않고 중단합니다."
}
Write-Host "안전장치 통과: 신선 수집 $freshCount개 (기준 $minExpected개 이상)"

# ================= 4.5 이전 데이터 승계 =================
# 목록에 안 나오는 변형상품(그룹 형제) 유지 — 현재 스키마로 정규화해 재추가.
# (가격/이름/규격은 이번 실행의 그룹 재조회에서 다시 갱신됨)
function OldProp($o, [string]$n) {
  if ($o.PSObject.Properties[$n]) { $o.$n } else { $null }
}
foreach ($oid in $old.Keys) {
  $o = $old[$oid]
  if ($items.ContainsKey($oid)) { continue }
  $og = OldProp $o 'gid'
  # 그룹에 속한 상품은 대표(gid==자기자신)도 유지한다.
  # (과거엔 대표를 제외해 크롤 실패 시 대표만 사라지는 사고가 있었음)
  if ($og -and $og -ne 'solo') {
    $items[$oid] = [pscustomobject]@{
      id = $oid; name = [string](OldProp $o 'name')
      company = [string]$(if (OldProp $o 'company') { OldProp $o 'company' } else { OldProp $o 'origin' })
      country = [string](OldProp $o 'country')
      spec = [string](OldProp $o 'spec')
      priceList = (OldProp $o 'priceList'); priceMember = (OldProp $o 'priceMember'); priceReal = (OldProp $o 'priceReal')
      cat1 = [string](OldProp $o 'cat1'); cat2 = [string](OldProp $o 'cat2')
      catLeaf = [string](OldProp $o 'catLeaf'); cats = @(OldProp $o 'cats')
      img = "$Base/data/product/img_m1_$oid"
      url = "$Base/shop/item.php?pd_idx=$oid"
      pkg = [string](OldProp $o 'pkg'); gid = [string]$og; hasGroup = $false
      code = [string](OldProp $o 'code')
    }
  }
}

# ================= 4.6 상세페이지 규격(변형) 크롤 =================
# 상세페이지의 그룹 테이블(형제 상품: 코드번호 + 규격 + 포장단위 + 가격)을 파싱.
# 그룹당 1회만 방문: 방문 시 형제 전원 covered 처리 + gid 기록 → 다음 실행부터 그룹 대표만 재방문.
function Parse-GroupRows([string]$html) {
  $anchors = [regex]::Matches($html, '<a href="/shop/item\.php\?pd_idx=(\d+)[^"]*">\s*(\d{2,6}-\d{2,6})\s*</a>')
  $rows = [System.Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt $anchors.Count; $i++) {
    $st = $anchors[$i].Index
    $en = if ($i + 1 -lt $anchors.Count) { $anchors[$i + 1].Index } else { [Math]::Min($st + 3500, $html.Length) }
    $reg = $html.Substring($st, $en - $st)
    $vid = $anchors[$i].Groups[1].Value

    $nm = ''
    foreach ($nmM in [regex]::Matches($reg, 'pd_idx=' + $vid + '[^"]*">([^<]+)</a>')) {
      $t = (Dec $nmM.Groups[1].Value)
      if ($t -notmatch '^\d{2,6}-\d{2,6}$') { $nm = $t; break }
    }
    # 회사: 이름 링크 직후 "<br>...[회사]" 만 인정 (이름 안의 [가격파괴] 같은 태그 오인 방지)
    $brand = ''
    if ($reg -match '</a>\s*<br>\s*(?:<span[^>]*>)?\s*\[([^\]]+)\]') { $brand = Dec $Matches[1] }
    $spec = ''
    foreach ($im in [regex]::Matches($reg, '<span class="impact">\s*([^<]+?)\s*</span>')) {
      $t = (Dec ($im.Groups[1].Value -replace '&nbsp;', ' ')).Trim()
      if ($t -and $t -notmatch '^개당' -and $t -notmatch '^-?[\d,]+\s*원?$' -and $t -notmatch '@') { $spec = $t; break }
    }
    # 이름 끝에 규격이 붙어 있으면 잘라냄 (목록 파서와 동일 규칙)
    if ($spec) {
      $spT2 = $spec.Trim()
      if ($spT2 -and $nm.TrimEnd().EndsWith($spT2)) {
        $nm = $nm.TrimEnd().Substring(0, $nm.TrimEnd().Length - $spT2.Length).Trim()
      }
    }
    $pkg = ''
    if ($reg -match '>\s*([0-9][^<>]{0,14}?/\s*pkg)') { $pkg = ($Matches[1] -replace '\s+', '') }
    $prices = [regex]::Matches($reg, '\d+@\s*([\d,]+)\s*원') | ForEach-Object { ToInt $_.Groups[1].Value }
    $pList = $null; $pMember = $null
    if ($prices.Count -ge 1) { $pList = $prices[0] }
    if ($prices.Count -ge 2) { $pMember = $prices[1] }

    $rows.Add([pscustomobject]@{ id = $vid; name = $nm; spec = $spec; pkg = $pkg
                                 company = $brand; priceList = $pList; priceMember = $pMember
                                 code = $anchors[$i].Groups[2].Value })
  }
  , $rows
}

# 경량 그룹 엔드포인트: POST /program/show_group_list.php (param1=pd_idx) → 그룹 전체 행 반환(~9KB)
function Get-GroupHtml([string]$pdIdx) {
  $r = Invoke-WebRequest -Uri "$Base/program/show_group_list.php" -Method Post `
    -Body "&param1=$pdIdx&param2=&param3=&param4=&param5=" `
    -ContentType 'application/x-www-form-urlencoded' `
    -WebSession $script:session -UserAgent $ua -UseBasicParsing -TimeoutSec 30
  [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

if ($Details) {
  # 방문 대상: 목록에 '규격보기' 버튼이 있는 상품만 (그룹 보유 확정 신호).
  # 같은 그룹의 형제가 이미 covered면 생략 → 그룹당 1회 요청.
  $targets = @($items.Keys | Where-Object {
    $rec = $items[$_]
    $rec.PSObject.Properties['hasGroup'] -and $rec.hasGroup
  })
  if ($DetailsMax -gt 0 -and $targets.Count -gt $DetailsMax) { $targets = $targets[0..($DetailsMax - 1)] }
  Write-Host "규격그룹 크롤 대상(규격보기 보유): $($targets.Count)개"
  $covered = @{}; $dv = 0; $newVar = 0
  foreach ($tid in $targets) {
    if ($covered.ContainsKey($tid)) { continue }
    try { $dh = Get-GroupHtml $tid } catch { Write-Warning "그룹조회 실패 $tid"; continue }
    $dv++
    $rep = $items[$tid]
    $covered[$tid] = 1
    $rows = Parse-GroupRows $dh
    $rep.gid = $(if ($rows.Count -ge 2) { $tid } else { 'solo' })
    foreach ($row in $rows) {
      $covered[$row.id] = 1
      if ($items.ContainsKey($row.id)) {
        $r2 = $items[$row.id]
        $r2.gid = $tid
        # 그룹 행이 정본: 이름(그룹 내 동일)·규격·회사는 그룹 값으로 덮어씀
        if ($row.name) { $r2.name = $row.name }
        if ($row.spec) { $r2.spec = $row.spec }
        if ($row.company) { $r2.company = $row.company }
        if ($row.pkg)  { $r2.pkg = $row.pkg }
        if ($row.code) { $r2.code = $row.code }
        # 안전망: 이름 끝에 규격이 남아있으면 제거
        if ($r2.spec) {
          $spT3 = $r2.spec.Trim()
          if ($spT3 -and $r2.name.TrimEnd().EndsWith($spT3) -and $r2.name.TrimEnd().Length -gt $spT3.Length) {
            $r2.name = $r2.name.TrimEnd().Substring(0, $r2.name.TrimEnd().Length - $spT3.Length).Trim()
          }
        }
        if ($null -eq $r2.priceList -and $null -ne $row.priceList)     { $r2.priceList = $row.priceList }
        if ($null -eq $r2.priceMember -and $null -ne $row.priceMember) { $r2.priceMember = $row.priceMember }
      } elseif ($row.name) {
        $newVar++
        $items[$row.id] = [pscustomobject]@{
          id = $row.id; name = $row.name
          company = $(if ($row.company) { $row.company } else { $rep.company })
          country = ''
          spec = $row.spec
          priceList = $row.priceList; priceMember = $row.priceMember; priceReal = $null
          cat1 = $rep.cat1; cat2 = $rep.cat2; catLeaf = $rep.catLeaf; cats = $rep.cats
          img = "$Base/data/product/img_m1_$($row.id)"
          url = "$Base/shop/item.php?pd_idx=$($row.id)"
          pkg = $row.pkg; gid = $tid; hasGroup = $false; code = $row.code
        }
      }
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    if ($dv % 100 -eq 0) { Write-Host "  그룹조회 진행 $dv/$($targets.Count) (신규 변형 $newVar)" }
  }
  Write-Host "그룹 크롤 완료: 요청 $($dv)회 · 신규 변형상품 $($newVar)개"

  # ================= 4.7 회사 → 제조국 맵 =================
  # 제조국은 상세페이지("회사/원산지 : 회사/국가")에만 있음.
  # 회사별로 1회만 상세를 조회해 국가를 알아내고 company-map.json에 캐시 → 이후 실행은 신규 회사만 조회.
  $mapFile = Join-Path $PSScriptRoot 'company-map.json'
  $cmap = @{}
  if (Test-Path $mapFile) {
    try {
      $mj = Get-Content $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($pr in $mj.PSObject.Properties) { $cmap[$pr.Name] = $pr.Value }
    } catch {}
  }
  # 회사별 샘플 상품 선정
  $needCompanies = @{}
  foreach ($it in $items.Values) {
    if ($it.company -and -not $cmap.ContainsKey($it.company) -and -not $needCompanies.ContainsKey($it.company)) {
      $needCompanies[$it.company] = $it.id
    }
  }
  Write-Host "제조국 조회 대상 회사: $($needCompanies.Count)곳 (캐시 $($cmap.Count)곳)"
  $cv = 0
  foreach ($cName in @($needCompanies.Keys)) {
    $sid = $needCompanies[$cName]
    try { $ch = Get-Html "$Base/shop/item.php?pd_idx=$sid" } catch { continue }
    $cv++
    # 형식: "회사/국가[회사검색]" — 회사명에 '/'가 올 수 있고 국가는 빈 값 가능 → 마지막 '/' 기준 분리
    $cm = [regex]::Match($ch, '회사/원산지[\s\S]{0,220}?mf_idx=(\d+)">(.*)/([^/<\[]*)\[')
    if ($cm.Success) {
      $cmap[$cName] = [pscustomobject]@{
        country = (Dec $cm.Groups[3].Value)
        mf      = $cm.Groups[1].Value
        label   = (Dec $cm.Groups[2].Value)
      }
    } else {
      $cmap[$cName] = [pscustomobject]@{ country = ''; mf = ''; label = '' }   # 실패도 캐시(재시도 방지)
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    if ($cv % 50 -eq 0) { Write-Host "  제조국 조회 $cv/$($needCompanies.Count)" }
  }
  # 국가 배정 (뱃지로 이미 채워진 country는 유지)
  foreach ($it in $items.Values) {
    if (-not $it.country -and $it.company -and $cmap.ContainsKey($it.company)) {
      $it.country = [string]$cmap[$it.company].country
    }
  }
  # 캐시 저장
  $cmapOut = [ordered]@{}
  foreach ($k in ($cmap.Keys | Sort-Object)) { $cmapOut[$k] = $cmap[$k] }
  $encM = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($mapFile, ($cmapOut | ConvertTo-Json -Depth 3), $encM)
  Write-Host "제조국 맵 저장: 회사 $($cmap.Count)곳 (신규 조회 $($cv)회)"

}
# (숨은 검색키워드는 harvest-keywords.ps1 이 keywords-map.json 으로 수집하고,
#  build.ps1 이 상품에 kw 필드로 붙인다.)

# ================= 5. 출력 =================
# 멀티샵 구조: 이 크롤러는 data-edent.json만 생성. 통합본(data.js)은 build.ps1이 만든다.
$list = $items.Values | Sort-Object name
$payload = [ordered]@{
  shop        = 'edent'
  generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  loggedIn    = $loggedIn
  count       = $list.Count
  items       = $list
}
$json = $payload | ConvertTo-Json -Depth 6
$enc = New-Object System.Text.UTF8Encoding($false)   # BOM 없음
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data-edent.json'), $json, $enc)
Write-Host ("완료: 상품 $($list.Count)개 · 요청 $($reqCount)회 · 회원가수집 $loggedIn")
