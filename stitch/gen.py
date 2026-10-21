import sys, json, urllib.request
sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import add_surrogate_to_request
def mcp(method, params=None, timeout=420):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params: payload["params"] = params
    req = urllib.request.Request("https://stitch.googleapis.com/mcp", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}, method="POST")
    add_surrogate_to_request(req, "custom.stitch", allowed_hosts=["stitch.googleapis.com"])
    resp = urllib.request.urlopen(req, timeout=timeout)
    body = resp.read().decode()
    for line in body.split("\n"):
        line = line.strip()
        if line.startswith("data:"): line = line[5:].strip()
        if line.startswith("{"): return json.loads(line)
    return json.loads(body)
mcp("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "muse-stitch-cli", "version": "1.0"}})
project = sys.argv[1]
name = sys.argv[2]
prompt = sys.argv[3]
out = sys.argv[4]
r = mcp("tools/call", {"name": "generate_screen_from_text", "arguments": {"projectId": project, "deviceType": "MOBILE", "prompt": prompt}}, timeout=420)
with open(out, "w") as f: json.dump(r.get("result", r), f)
print("saved", out)
