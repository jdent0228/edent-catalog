# 세일글로벌(seilglobal.co.kr) 상품 카탈로그 크롤러 (MakeShop, EUC-KR)
# 사용법:  powershell -ExecutionPolicy Bypass -File crawl-seil.ps1
# 결과:  data-seil.json (비로그인 판매가 기준; robots.txt 전면 허용)
#
# 목록 구조: shopbrand.html?xcode=XX&page=N — <tr class="item-list"> 단위
#   thumb img(MS_prod_img_m) | prd-name(branduid+이름) | prd-standard(규격) |
#   prd-brand(회사) | prd-code(상품코드) | strike 소비자가 | span.memberPrice 판매가

param(
  [int]$DelayMs = 700,
  [int]$MaxCats = 0            # 0=전체, >0 테스트용
)

$ErrorActionPreference = 'Stop'
$Base = 'https://www.seilglobal.co.kr'
$ua   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$kr   = [System.Text.Encoding]::GetEncoding('euc-kr')

function Get-Html([string]$url) {
  $r = Invoke-WebRequest -Uri $url -UserAgent $ua -UseBasicParsing -TimeoutSec 40
  $kr.GetString($r.RawContentStream.ToArray())
}
function Dec([string]$s) { [System.Net.WebUtility]::HtmlDecode($s).Trim() }
function ToInt($s) { if ($s) { [int]((($s) -replace '[^\d]', '')) } else { $null } }

# ================= 1. 카테고리(xcode) 목록 + 이름 =================
# 데스크톱 GNB는 이미지 메뉴라 이름이 없음 → 모바일(m.seilglobal.co.kr)의 텍스트 메뉴에서
# 전체 xcode 목록과 이름을 수집 (커버리지도 모바일이 훨씬 넓음: ~130개 vs 25개)
$catName = @{}
$xcodeSet = @{}
$uaMobile = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1'
function Get-HtmlUA([string]$url, [string]$agent) {
  $r = Invoke-WebRequest -Uri $url -UserAgent $agent -UseBasicParsing -TimeoutSec 40
  $kr.GetString($r.RawContentStream.ToArray())
}
foreach ($src in @(@{u="http://m.seilglobal.co.kr/"; a=$uaMobile}, @{u="$Base/"; a=$ua})) {
  try { $navHtml = Get-HtmlUA $src.u $src.a } catch { Write-Warning "메뉴 로드 실패: $($src.u)"; continue }
  # 데스크톱은 shopbrand.html?xcode=, 모바일은 /m/product_list.html?type=X&xcode= — 경로 무관하게 xcode만 잡음
  foreach ($m in [regex]::Matches($navHtml, '(?s)<a[^>]+[?&]xcode=(\d+)[^"]*"[^>]*>(.*?)</a>')) {
    $xc = $m.Groups[1].Value
    $xcodeSet[$xc] = 1
    $nm = Dec ((($m.Groups[2].Value -replace '<[^>]+>', '') -replace '\s+', ' ') -replace '\s*>\s*$', '')
    if ($nm -and $nm.Length -ge 2 -and $nm.Length -le 30 -and -not $catName.ContainsKey($xc)) { $catName[$xc] = $nm }
  }
}
$xcodes = @($xcodeSet.Keys | Sort-Object)
if ($MaxCats -gt 0 -and $xcodes.Count -gt $MaxCats) { $xcodes = $xcodes[0..($MaxCats - 1)] }
Write-Host "세일글로벌 카테고리: $($xcodes.Count)개 (이름 확보 $($catName.Count)개)"

# ================= 2. 목록 파싱 =================
function Parse-SeilList([string]$html) {
  $out = [System.Collections.Generic.List[object]]::new()
  $rows = [regex]::Matches($html, '(?s)<tr class="item-list">(.*?)</tr>')
  foreach ($r in $rows) {
    $b = $r.Groups[1].Value
    $idM = [regex]::Match($b, 'branduid=(\d+)')
    if (-not $idM.Success) { continue }
    $bid = $idM.Groups[1].Value

    $nm = ''
    $nmM = [regex]::Match($b, '(?s)class="prd-name"[^>]*>\s*<a[^>]*>(.*?)</a>')
    if ($nmM.Success) { $nm = Dec (($nmM.Groups[1].Value) -replace '<[^>]+>', '') }
    if (-not $nm) { continue }

    $spec = ''
    if ($b -match 'class="prd-standard"[^>]*>([^<]*)<') { $spec = Dec $Matches[1] }
    $brand = ''
    if ($b -match 'class="prd-brand"[^>]*>([^<]*)<') { $brand = Dec $Matches[1] }
    $code = ''
    if ($b -match 'class="prd-code"[^>]*>[^:<]*:\s*([^<]+)<') { $code = (Dec $Matches[1]) }

    $pList = $null
    if ($b -match '<strike>[^<]*?([\d,]{3,})\s*원') { $pList = ToInt $Matches[1] }
    $pSell = $null
    if ($b -match 'class="memberPrice"[^>]*>\s*([\d,]+)\s*<') { $pSell = ToInt $Matches[1] }
    elseif ($b -match '판매가[^\d]{0,30}([\d,]{3,})\s*원') { $pSell = ToInt $Matches[1] }

    $img = ''
    $imgM = [regex]::Match($b, '<img[^>]+class="MS_prod_img_m"[^>]+src="([^"]+)"')
    if (-not $imgM.Success) { $imgM = [regex]::Match($b, 'class="thumb"[\s\S]{0,300}?<img[^>]+src="([^"]+)"') }
    if ($imgM.Success) {
      $img = $imgM.Groups[1].Value
      if ($img.StartsWith('//')) { $img = 'https:' + $img }
      elseif ($img.StartsWith('/')) { $img = $Base + $img }
    }

    # 세일글로벌의 'prd-standard(규격)'은 실제로는 포장단위(EA, Set, pkg/5EA …)
    $out.Add([pscustomobject]@{
      id = $bid; name = $nm; pkg = $spec; spec = ''; company = $brand; code = $code
      priceList = $pList; priceSell = $pSell; img = $img
    })
  }
  , $out
}

# ================= 3. 순회 =================
$items = @{}
$reqCount = 0
$ci = 0
foreach ($xc in $xcodes) {
  $ci++
  $c1 = if ($catName.ContainsKey($xc)) { $catName[$xc] } else { "분류$xc" }
  $page = 1
  $prevIds = ''
  while ($true) {
    try { $html = Get-Html "$Base/shop/shopbrand.html?xcode=$xc&page=$page" }
    catch { Write-Warning "요청 실패 xcode=$xc p$page"; break }
    $reqCount++
    $rows = Parse-SeilList $html
    if ($rows.Count -eq 0) { break }
    # 같은 목록 반복(마지막 페이지 초과) 감지
    $idsSig = ($rows | ForEach-Object { $_.id }) -join ','
    if ($idsSig -eq $prevIds) { break }
    $prevIds = $idsSig

    foreach ($p in $rows) {
      if ($items.ContainsKey($p.id)) {
        $rec = $items[$p.id]
        if ($rec.cats -notcontains $c1) { $rec.cats += $c1 }
        continue
      }
      $items[$p.id] = [pscustomobject]@{
        id = $p.id; name = $p.name; company = $p.company; country = ''
        spec = $p.spec
        priceList = $p.priceList; priceMember = $null; priceReal = $p.priceSell
        cat1 = $c1; cat2 = ''; catLeaf = ''; cats = @($c1)
        img = $p.img
        url = "$Base/shop/shopdetail.html?branduid=$($p.id)"
        pkg = $p.pkg; gid = ''; hasGroup = $false; code = $p.code
        shop = 'seil'
      }
    }
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    $page++
    if ($page -gt 60) { break }   # 안전장치
  }
  Write-Host "  [$ci/$($xcodes.Count)] $c1 (xcode=$xc) 누적 $($items.Count)"
}

# ================= 3.5 상품명에서 규격 분리 (이덴트와 동일 구조로) =================
# 세일글로벌은 규격 필드가 따로 없고 상품명에 규격이 붙어 있다.
#   예) "토마스 게이트 바 32mm" / "토마스 게이트 바 25mm"
# 같은 회사의 상품명들을 비교해 '공통 접두어(=진짜 상품명)'와 '뒤에 남는 부분(=규격)'을 찾는다.
# 규칙 기반 추측이 아니라, 실제 데이터에서 2개 이상이 공유하는 접두어만 인정한다.
# 규격으로 인정하는 '이름 끝' 패턴만 떼어낸다 (문장 중간을 자르지 않도록 보수적으로)
#   #678771 / 32mm / (22.5mm) / 4.0x10mm  같은 규격·치수 표기
$SPEC_RX = @(
  '\s*(#[A-Za-z0-9][A-Za-z0-9\-\.\/]*)$',
  '\s*\(?(\d+(?:\.\d+)?\s?(?:mm|cm|ml|㎜|㎝|g|kg|인치|호))\)?$',
  '\s*(\d+(?:\.\d+)?\s?[xX×]\s?\d+(?:\.\d+)?\s?(?:mm|cm|㎜)?)$'
)
function Split-Spec([string]$nm) {
  $base = $nm.Trim(); $spec = ''
  for ($pass = 0; $pass -lt 2; $pass++) {
    $hit = $false
    foreach ($rx in $SPEC_RX) {
      $m = [regex]::Match($base, $rx)
      if ($m.Success) {
        $cand = $base.Substring(0, $m.Index).TrimEnd()
        # 괄호가 열린 채 끊기면(문장 중간) 분리하지 않음
        $ob = ([regex]::Matches($cand, '[\(\[]')).Count
        $cb = ([regex]::Matches($cand, '[\)\]]')).Count
        if ($cand.Length -ge 8 -and $ob -eq $cb) {
          $spec = ($m.Groups[1].Value.Trim() + ' ' + $spec).Trim()
          $base = $cand; $hit = $true; break
        }
      }
    }
    if (-not $hit) { break }
  }
  , @($base, $spec)
}

$specSet = 0
foreach ($it in $items.Values) {
  $r = Split-Spec $it.name
  if ($r[1]) { $it.name = $r[0]; $it.spec = $r[1]; $specSet++ }
}
# 같은 회사·같은 상품명이면서 규격이 서로 다른 것들만 그룹으로 묶는다
$groupSet = 0
$gkey = @{}
foreach ($it in $items.Values) {
  if (-not $it.spec) { continue }
  $k = "$($it.company)|$($it.name)"
  if (-not $gkey.ContainsKey($k)) { $gkey[$k] = [System.Collections.Generic.List[object]]::new() }
  $gkey[$k].Add($it)
}
foreach ($k in $gkey.Keys) {
  $arr = @($gkey[$k])
  if ($arr.Count -lt 2) { continue }
  if (@($arr | ForEach-Object { $_.spec } | Sort-Object -Unique).Count -lt 2) { continue }
  $gid = ($arr | Sort-Object spec)[0].id
  foreach ($m in $arr) { $m.gid = $gid }
  ($arr | Where-Object { $_.id -eq $gid })[0].hasGroup = $true
  $groupSet++
}
Write-Host "규격 분리: $($specSet)개 상품 / 그룹 $($groupSet)개"

# ================= 4. 안전장치 + 출력 =================
# 크롤이 사실상 실패했는데 좋은 데이터를 덮어쓰는 것을 막는다.
$minExpected = 1000
$prevFile = Join-Path $PSScriptRoot 'data-seil.json'
if (Test-Path $prevFile) {
  try {
    $prev = Get-Content $prevFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($prev.count -gt 1000) { $minExpected = [int]($prev.count * 0.6) }
  } catch {}
}
if ($items.Count -lt $minExpected) {
  throw "세일글로벌 크롤 실패 의심: 수집 $($items.Count)개 (기대 최소 $minExpected개). 데이터를 쓰지 않고 중단합니다."
}
Write-Host "안전장치 통과: 수집 $($items.Count)개 (기준 $minExpected개 이상)"

$list = $items.Values | Sort-Object name
$payload = [ordered]@{
  shop        = 'seil'
  generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  count       = $list.Count
  items       = $list
}
$json = $payload | ConvertTo-Json -Depth 6
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'data-seil.json'), $json, $enc)
Write-Host "완료: 세일글로벌 $($list.Count)개 · 요청 $($reqCount)회"
