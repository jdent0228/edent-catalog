# 이덴트 상품 카탈로그 (edent.co.kr)

edent.co.kr 전 상품의 **품명·가격(정가/회원가)·이미지**를 크롤링해 **검색 가능한 웹페이지**로 보여줍니다.
GitHub Actions가 **매시간** 자동 갱신합니다.

## 구성
| 파일 | 역할 |
|------|------|
| `crawl.ps1` | 크롤러. 카테고리 트리를 읽어 소·중분류 목록 페이지를 순회, `data.js`/`data.json` 생성 |
| `index.html` | 검색·필터·이미지 카탈로그 뷰어 (단일 파일, 프레임워크 없음) |
| `data.js` / `data.json` | 크롤 결과 (Actions가 자동 갱신·커밋) |
| `.github/workflows/refresh.yml` | 매시 정각 크론 |
| `.claude/serve.ps1` | 로컬 미리보기 서버 |

## 크롤 방식
- 카테고리 트리 `program/show_cate_all_make.php` → 대(12)/중(81)/소(599) 분류.
- **소분류 + 중분류 버킷을 모두 순회**하고 `pd_idx`로 dedup (부모·자식이 상호 완전포함이 아니라 합집합이 필요).
- 목록 페이지(`shop_list.php`)에 품명·가격·이미지가 모두 있어 **개별 상품 페이지는 열지 않음**.
- **회원가**는 로그인 세션에서만 보이므로 크롤러가 로그인 후 수집.
- robots.txt의 `Crawl-delay: 1`을 지켜 요청 간 1초 대기.

## 자격증명 설정
비밀번호는 저장소에 커밋되지 않습니다.

### 클라우드(GitHub Actions)
저장소 **Settings → Secrets and variables → Actions → New repository secret** 에서 등록:
- `EDENT_ID` — edent.co.kr 아이디
- `EDENT_PW` — 비밀번호

미설정 시에도 크롤은 동작하지만 **정가만** 수집됩니다(회원가 빈값).

### 로컬 테스트
```powershell
Copy-Item secret.local.ps1.example secret.local.ps1   # 그리고 아이디/비번 입력
powershell -ExecutionPolicy Bypass -File crawl.ps1
```

## 로컬 미리보기
```powershell
powershell -ExecutionPolicy Bypass -File .claude/serve.ps1
# http://localhost:4323/ 접속
```

## 배포 (GitHub Pages)
1. 이 폴더를 공개 저장소 `jdent0228/edent-catalog` 로 push.
2. `EDENT_ID` / `EDENT_PW` 시크릿 등록.
3. Actions 탭에서 **이덴트 카탈로그 갱신 → Run workflow** 로 첫 크롤 실행(약 10~15분).
4. **Settings → Pages → Source: main / (root)** 활성화 → 공개 URL에서 열람.
5. 이후 매시 정각 자동 갱신.

## 참고
- 데이터 출처: [edent.co.kr](https://www.edent.co.kr) (개인 열람용).
- 이미지는 원본 서버 핫링크(저장 안 함).
