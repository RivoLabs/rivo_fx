# Devtools (/fxdev)

`/fxdev` is an in-game view of every resource that uses Rivo FX, on the server and on your own client: live fibers, traces, failures and metrics. Use it while building or debugging a resource on a dev server; only players with the `rivo_fx.devtools` ACE can open it.

## Opening it

```cfg
# server.cfg
add_ace group.admin rivo_fx.devtools allow
```

| Command | What it does |
|---|---|
| `/fxdev` | opens on the last view, or closes when open |
| `/fxdev <view>` | opens on (or switches to) `overview`, `fibers`, `traces`, `failures` or `metrics` |

The server checks the ACE on every request, not only when opening. A player without it sees a chat message naming the permission. `Esc` closes the screen; `/` focuses the filter.

## Views

| View | Shows |
|---|---|
| Overview | each resource and side with live fibers, timers, finished spans, failures and the last failure; a live-fibers chart for the last 60 seconds |
| Fibers | the fibers alive right now, each child under its parent, with status (`waiting`, `running`, `interrupting`), age, child count and the span it is in |
| Traces | recent traces as a waterfall; a client's `Fx.rpc` call and the server handler it reached are one trace. Click a span for its attributes, events and traceparent |
| Failures | error logs, unhandled fiber failures and defects, with the full cause, fields, fiber and a link to the trace |
| Metrics | every metric and label set; histograms with count, average, p50, p95 and p99 |

Controls: show the server, the client or both; filter by resource or name; pause updates; switch between the dark and light theme (remembered). In Traces, "errors only" hides traces without a failed span.

## Busy servers

- The overview lists the busiest resources first (failures, then live fibers, then spans) and stops at 50 rows until you choose "Show all". Column headers sort.
- Fibers fold into one group per resource and side; with more than 60 fibers the groups start folded. At most 400 fiber rows are drawn until "Show all", and each resource sends at most its first 200.
- The same failure message from one resource is one row with a count.
- Metric families show 8 label sets until "Show all".
- `rivo_fx` itself is not listed.

## What it costs

It asks for data once a second while open and not at all when closed. When collecting takes longer (hundreds of resources), the interval grows with the measured cost, up to every 5 seconds, and the status line says so. Spans and failures are sent once each; every resource keeps the last 200 spans and 50 failures.

## Privacy

Spans and failures can hold player ids, payload fields and error details. Give the ACE only to people who can already read your server console. All text is shown as text, never as HTML, so a player-controlled string cannot run in an admin's screen.

## Notes

- JS/TS resources (`@rivolabs/fx`) do not appear in `/fxdev` yet.
- Span times come from each side's own clock. The waterfall places a span from another clock (for example the server inside a client call) inside its parent and marks it with `~`.

See [Metrics, tracing and logs](observability.md) for the spans and metrics behind these views.
