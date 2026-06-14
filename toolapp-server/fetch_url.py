import sys, json, urllib.parse
from curl_cffi import requests as curl_req

def fetch(url: str) -> dict:
    redirect_url = url
    status_code = 0
    html = ""

    resp = curl_req.get(
        url,
        impersonate="chrome124",
        timeout=30,
        allow_redirects=True,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                          "AppleWebKit/537.36 (KHTML, like Gecko) "
                          "Chrome/124.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
    )
    html = resp.text
    status_code = resp.status_code
    redirect_url = str(resp.url)

    return {
        "html": html,
        "finalUrl": redirect_url,
        "statusCode": status_code,
    }

if __name__ == "__main__":
    args = json.loads(sys.stdin.read())
    url = args["url"]
    try:
        result = fetch(url)
        result["success"] = True
        print(json.dumps(result, ensure_ascii=False), flush=True)
    except Exception as e:
        err = {"success": False, "error": str(e)}
        print(json.dumps(err, ensure_ascii=False), flush=True)
        print(str(e), file=sys.stderr, flush=True)
        sys.exit(1)
