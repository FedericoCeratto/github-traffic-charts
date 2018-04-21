## GitHub Traffic Charts
## Copyright 2018 Federico Ceratto <federico.ceratto@gmail.com>
## Released under LGPLv3 License, see LICENSE file

import os,
  httpclient,
  json,
  ospaths,
  posix,
  streams,
  strutils,
  tables,
  times

from sequtils import toSeq

const
  rel_conf_fname = "./etc/github_traffic_charts.conf.json"
  rel_status_fname = "./var/lib/github_traffic_charts/status.json"
  rel_output_dir_name = "./var/lib/github_traffic_charts/output"
  baseurl = "https://api.github.com"
  palette = ["#3366CC","#DC3912","#FF9900","#109618","#990099","#3B3EAC","#0099C6","#DD4477",
    "#66AA00","#B82E2E","#316395","#994499","#22AA99","#AAAA11","#6633CC","#E67300",
    "#8B0707","#329262","#5574A6","#3B3EAC"]

type
  Chart = ref object
    ctype, gran, blob: string
  Charts = seq[Chart]

include "templates/page.tmpl"


onSignal(SIGABRT):
  ## Handle SIGABRT from systemd
  # Lines printed to stdout will be received by systemd and logged
  # Start with "<severity>" from 0 to 7
  echo "<2>Received SIGABRT"
  quit(1)

onSignal(SIGQUIT):
  echo "github_traffic_charts exiting..."
  quit(1)

var color_cnt = -1
proc gen_color(): string =
  color_cnt.inc
  return palette[color_cnt %% palette.len]

proc fetch_with_headers(conf: JsonNode, path: string): (JsonNode, HttpHeaders) =
  let url = baseurl & path
  var client = newHttpClient()
  let headers = newHttpHeaders({
    "Authorization": "token " & conf["token"].str,
    "Content-Type": "application/json"
  })
  let r = client.request(url, $HttpGet, "", headers)
  if r.headers["X-RateLimit-Remaining"].parseInt() < 100:
    echo "WARNING: low rate limit remaining: ", r.headers["X-RateLimit-Remaining"]

  let body = r.bodyStream.readAll()
  var q: JsonNode
  try:
    q = parseJson(body)
  except Exception:
    echo "ERROR: unable to parse body:\n---\n$#\n---" % body
    raise newException(Exception, "ERROR: unable to parse body")

  if q.kind == JObject and q.hasKey("message"):
    raise newException(Exception, "ERROR: " & q["message"].str)
  return (q, r.headers)

proc fetch(conf: JsonNode, path: string): JsonNode =
  ## Call GitHub API, parse JSON response
  let (r, h) = fetch_with_headers(conf, path)
  return r

proc abspath(path: string): string =
  return joinPath(getCurrentDir(), path[2..^1])

proc list_repo_names(conf: JsonNode, owner: string, repos: JsonNode): seq[string] =
  ## Extract or fetch repo names
  result = @[]
  if repos.len > 0:
    # use configured repos
    for r in repos:
      result.add r.str
    return

  echo "listing available repos"
  let path_without_page =
    if owner.startsWith("user:"):
      "/users/$#/repos?page=" % owner[5..^1]
    elif owner.startsWith("org:"):
      "/users/$#/repos?page=" % owner[4..^1]
    else:
      raise newException(Exception, "owners must start with user: or org:")

  for cnt in 1..20:
    let path = path_without_page & $cnt
    let (j, headers) = fetch_with_headers(conf, path)

    for project in j:
      # TODO: track project["forks_count"], project["watchers_count"], project["stargazers_count"]
      #echo project["forks"]
      #echo project["watchers"]
      #echo project["stargazers_count"]
      result.add project["name"].str

    let link = $headers["Link"]
    if not link.contains("""rel="next"""):
      break


proc update(status: var JsonNode, conf: JsonNode) =
  # status:
  # owner -> repo_name -> timestamp -> "view|clone" -> count
  for owner, repos in conf["repos"].pairs:
    let repo_names = list_repo_names(conf, owner, repos)
    echo "scanning $# repositories belonging to $#" % [$repo_names.len, owner]

    for repo_name in repo_names:
      let views = fetch(conf, "/repos/$#/$#/traffic/views" % [owner[5..^1], repo_name])
      for view_event in views["views"]:
        let ts = view_event["timestamp"].str
        let cnt = view_event["uniques"].getInt()
        status{owner, repo_name, ts, "view"} = cnt.newJInt

      let r = fetch(conf, "/repos/$#/$#/traffic/clones" % [owner[5..^1], repo_name])
      for clone_event in r["clones"]:
        let ts = clone_event["timestamp"].str
        let cnt = clone_event["uniques"].getInt()
        status{owner, repo_name, ts, "clone"} = cnt.newJInt

proc pick_popular_repos(conf: JsonNode, t0: times.Time, start: int, repos: JsonNode): seq[string] =
  ## Sort repos by views and pick most popular ones
  let limit = conf["max-repos-per-chart"].getInt()
  var popular = initCountTable[string]()
  for repo_name, timestamps in repos.pairs:
    for daycount in start..0:
      let ts = utc(t0 + daycount.days).format("yyyy-MM-dd") & "T00:00:00Z"
      if timestamps.hasKey(ts) and timestamps[ts].hasKey("view"):
        let views = timestamps{ts, "view"}.getInt()
        popular.inc(repo_name, views)

  popular.sort()
  result =
    if popular.len <= limit:
      # repos without any datapoint are not in `popular`
      toSeq(popular.keys)
    else:
      toSeq(popular.keys)[0..<limit]

proc generate_day_charts(conf: JsonNode, owner: string, repos: JsonNode): string =
  let t0 = getTime()

  var chart = %* {
    "type": "line",
    "data": {
      "labels": [],
    },
    "options": {
      "responsive": true,
      "maintainAspectRatio": false,
      "title": {
        "display": true,
        "text": "GitHub traffic"
      },
      "tooltips": {
        "mode": "index",
        "intersect": false,
      },
      "hover": {
        "mode": "nearest",
        "intersect": true
      },
      "scales": {
        "xAxes": [{
          "display": true,
          "scaleLabel": {
            "display": true,
            "labelString": "Day"
          }
        }],
        "yAxes": [{
          "display": true,
          "scaleLabel": {
            "display": true,
            "labelString": "Unique views"
          }
        }]
      }
    }
  }
  chart["data"]{"labels"} = newJArray()
  chart["data"]{"datasets"} = newJArray()

  let start = -1 * conf["charted-days"].getInt()
  # add x-axis labels
  for daycount in start..0:
    let ts = utc(t0 + daycount.days).format("MM-dd")
    chart["data"]["labels"].add ts.newJString

  # pick most popular repos
  let repo_names = pick_popular_repos(conf, t0, start, repos)

  for repo_name in repo_names:
    let timestamps = repos[repo_name]
    let col = gen_color()
    var item = %* {
      "label": repo_name,
      "fill": false,
      "backgroundColor": col,
      "borderColor": col,
      "data": @[]
    }
    for daycount in start..0:
      let ts = utc(t0 + daycount.days).format("yyyy-MM-dd") & "T00:00:00Z"
      let val =
        if timestamps.hasKey(ts) and timestamps[ts].hasKey("view"):
          timestamps{ts, "view"}
        else:
          0.newJInt

      item["data"].add val

    chart["data"]["datasets"].add item

  return chart.pretty


proc generate_week_charts(conf: JsonNode, owner: string, repos: JsonNode): string =
  let t0 = getTime()

  var chart = %* {
    "type": "line",
    "data": {
      "labels": [],
    },
    "options": {
      "responsive": true,
      "maintainAspectRatio": false,
      "title": {
        "display": true,
        "text": "GitHub traffic"
      },
      "tooltips": {
        "mode": "index",
        "intersect": false,
      },
      "hover": {
        "mode": "nearest",
        "intersect": true
      },
      "scales": {
        "xAxes": [{
          "display": true,
          "scaleLabel": {
            "display": true,
            "labelString": "Week"
          }
        }],
        "yAxes": [{
          "display": true,
          "scaleLabel": {
            "display": true,
            "labelString": "Unique views"
          }
        }]
      }
    }
  }
  chart["data"]{"labels"} = newJArray()
  chart["data"]{"datasets"} = newJArray()

  let start = -7 * conf["charted-weeks"].getInt()
  # add x-axis labels
  for daycount in start..0:
    if daycount %% 7 == 6:
      let ts = utc(t0 + daycount.days).format("MM-dd")
      chart["data"]["labels"].add ts.newJString

  # pick most popular repos
  let repo_names = pick_popular_repos(conf, t0, start, repos)

  for repo_name in repo_names:
    let timestamps = repos[repo_name]
    let col = gen_color()
    var item = %* {
      "label": repo_name,
      "fill": false,
      "backgroundColor": col,
      "borderColor": col,
      "data": @[]
    }
    var week_total = 0
    for daycount in start..0:
      let ts = utc(t0 + daycount.days).format("yyyy-MM-dd") & "T00:00:00Z"
      if timestamps.hasKey(ts) and timestamps[ts].hasKey("view"):
        week_total.inc timestamps{ts, "view"}.getInt()

      if daycount %% 7 == 6:
        item["data"].add week_total.newJInt
        week_total = 0

    chart["data"]["datasets"].add item

  return chart.pretty

proc update_and_store(status: var JsonNode, conf: JsonNode, status_fname: string) =
  status.update(conf)
  writeFile(status_fname & ".tmp", status.pretty)
  moveFile(status_fname & ".tmp", status_fname)


proc main() =

  let
    conf_fname = abspath rel_conf_fname
    status_fname = abspath rel_status_fname
    output_dir_name = abspath rel_output_dir_name

  echo "github_traffic_charts starting... UID: ", geteuid()
  echo "reading ", conf_fname
  let jconf = readFile conf_fname
  let conf = parseJson(jconf)
  echo "creating " & output_dir_name & " if needed"
  createDir output_dir_name
  var status: JsonNode
  try:
    status = parseJson(readFile(status_fname))
    echo "loaded ", status_fname
  except Exception:
    echo "initializing ", status_fname
    writeFile(status_fname, """{}""")
    status = parseJson(readFile(status_fname))

  while true:
    status.update_and_store(conf, status_fname)
    for owner, repos in status.pairs:
      let
        daily = conf.generate_day_charts(owner, repos)
        weekly = conf.generate_week_charts(owner, repos)
        charts = @[
          Chart(ctype:"views", gran:"day", blob:daily),
          Chart(ctype:"views", gran:"week", blob:weekly)
        ]
        ow = owner.split(':')[1]
        out_fn = output_dir_name / ow & ".html"
        html = generate_html_page(charts)
      writeFile(out_fn, html)
      echo out_fn & " written"

    sleep 24 * 3600 * 1000


when isMainModule:
  main()
