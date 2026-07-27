# notes-service

A small notes API in Koka: HTTP/1.1 over TCP, JSON in and out, SQLite for
storage, structured logs, and cancellation-aware cleanup throughout.

This is the reference service for the Milestone-4 engineering program.  It
exists to exercise the libraries under `koka-packages/`, not to be a product.

## Setup

You need the compiler from the sibling `koka` checkout (it provides the project
commands and the `[native]` support this project relies on), plus `libuv` and
`sqlite3`.  The workspace's `kk` wrapper supplies all of that:

```sh
../../kk fetch --locked     # resolve dependencies from koka.lock
../../kk test               # unit tests
../../kk build --release    # optimized build
../../kk run                # start the server
```

`kk` runs the compiler inside `nix develop ../../koka`, which is what puts
`pkg-config`, `libuv` and `sqlite3` on the path.  With those installed system
wide, plain `koka` works too.

Integration and stress tests start a real server process:

```sh
./run-integration-tests.sh
./run-integration-tests.sh --asan     # under AddressSanitizer/UBSan/LeakSanitizer
```

46 assertions covering readiness, the item lifecycle, malformed and oversized
input, routing, 40 concurrent creates, stress (connect/disconnect churn, 100
short requests, keep-alive, a slow client, a client that vanishes mid-request,
an abandoned request), logging, graceful shutdown, and persistence across a
restart. All pass, with and without the sanitizers.

Several of these assertions check their own setup, which is not decoration:
`curl` prints `000` for connection-refused, DNS failure *and* its own timeout,
so matching on it accepted a crashed server as a passing test; and a probe
piped into `nc` with `|| true` degrades silently to "is /health still 200?" on
a machine without `nc`. The counts and the connection-reuse check exist so a
no-op cannot pass.

A note for anyone extending the suite: `wait` with no arguments waits for
*every* background job, including the server the script started with `&`. Use
`wait "${client_pids[@]}"`. A bare `wait` made the whole concurrency and stress
section run against a server that had already shut down, which looked exactly
like a server that could not handle concurrent load.

## Configuration

All optional, all read from the environment:

| variable       | default     | meaning                                  |
| -------------- | ----------- | ---------------------------------------- |
| `NOTES_HOST`   | `127.0.0.1` | bind address                             |
| `NOTES_PORT`   | `8080`      | port; `0` asks the OS for a free one. A value that is not a decimal integer refuses to start rather than falling back |
| `NOTES_DB`     | `notes.db`  | SQLite database file                     |
| `NOTES_LOG`    | `info`      | `debug` \| `info` \| `warn` \| `error`; anything else refuses to start |
| `NOTES_RUN_MS` | `0`         | stop after this many ms; `0` runs forever |

`NOTES_RUN_MS` exists so the integration tests can let the server shut itself
down instead of killing it — which is what makes graceful shutdown observable.

The database file is created on first run and migrated in place.  Migrations
live in `src/notes/store.kk` and each runs in its own transaction; running them
twice is a no-op.

## Requests

```sh
curl localhost:8080/health
curl -X POST -H 'content-type: application/json' \
     -d '{"title":"buy milk","body":"semi-skimmed"}' localhost:8080/items
curl localhost:8080/items
curl localhost:8080/items/1
curl -X DELETE localhost:8080/items/1
```

| method   | path         | success | notes                              |
| -------- | ------------ | ------- | ---------------------------------- |
| `GET`    | `/health`    | 200     | touches the database               |
| `GET`    | `/items`     | 200     | newest first, at most 100          |
| `GET`    | `/items/:id` | 200     | 404 when absent                    |
| `POST`   | `/items`     | 201     | returns the stored note            |
| `DELETE` | `/items/:id` | 204     | 404 when absent                    |

Errors are separated by whose fault they are: 400 for malformed JSON, 415 for
the wrong content type, 422 for a well-formed document that fails validation,
413 for an oversized body, 404/405 from the router, and 500 with a generic body
for anything internal — the detail goes to the log, never to the client.

## Architecture

```
  main.kk            configuration, wiring, shutdown
    notes/api.kk     routes, hand-written JSON codecs, validation
    notes/store.kk   prepared statements, transactions, migrations
      http/          message parsing, router, connection loop
      runtime/       libuv event loop, tasks, TCP, channels
      sqlite/        the SQLite binding
      logging/       structured logging as an effect
```

One task per connection, all inside one task group, so a connection cannot
outlive the server.  The event loop is single threaded: a database connection
is used by one task at a time by construction, which is why there is no pool
and no locking.

## How Koka is used

**Handlers read as the sequence of checks they are.**  Every step in a request
either yields a value or short-circuits with the response to send, which is
`either<response,a>` — spelled `step<a>` here.  `with x <- s.or-respond`
desugars to `or-respond(s, fn(x) ...)`, so the rest of the handler becomes the
continuation and the failure path is stated once:

```koka
fun create-item( d : database, r : request ) : <async,logger|io> response
  with j             <- r.json-body.or-respond
  with (title, body) <- new-note(j).or-respond
  with n             <- attempt({ create-note(d, title, body) }).or-respond
  created-json(note-json(n))
```

Four checks, four lines, in the order they happen.  Written with `match` the
same handler nests four deep and the interesting line is the innermost one.
The second line binds a *pattern*, which is the construct
[koka-lang/koka#914](https://github.com/koka-lang/koka/pull/914) fixes — it
aborted the compiler before that.

Each step names its own failure, so the status codes are decided where the
knowledge is: `json-body` distinguishes a missing content type (415) from a
body that will not parse (400), `new-note` returns 422 because a well-formed
document this API declines is not a malformed one, and `attempt` turns anything
the store raises into a logged 500 — after re-raising cancellation, which is
the server stopping rather than a request failing.

**The store is an effect, and the tests give it a different meaning.**  The
routes never mention SQLite:

```koka
pub fun list-items() : <notes,async,logger|io> response
  with ns <- attempt({ list-from-store(page-size) }).or-respond
  ok-json(notes-json(ns))
```

`routes(d)` installs `with-sqlite(d)`, so the service talks to the database.
`unit-test.kk` installs `with-memory(seed)` instead, and the same handlers run
over a list — no file, no database, no clock.  That is what the effect buys
over a `:database` argument: a connection parameter makes the store swappable
for *another database*, an effect makes it swappable for something that is not
a database at all, so the HTTP surface can be tested without one.

The in-memory handler numbers ids from one and derives `created` from a fixed
instant, so tests assert on exact ids and timestamps — which the SQLite
handler, taking its timestamps from the clock, cannot offer.  Eight tests
cover status codes, validation and codecs this way and open nothing.

**Logging** is an effect (`logger`).  A handler says *what* happened; the
handler installed at the edge decides where it goes and what context it
carries.  The server installs it per connection with the request id already in
context, so anything a handler logs carries that id without threading it
through.  It is installed per connection rather than around the whole server
because `spawn` fixes a task's effect row — a task cannot inherit an ambient
`logger` from its parent.

**Cancellation** is the `async` effect's doing.  A cancelled task is resumed
once with `Cancelled`, every suspension point turns that into an exception, and
that exception unwinds through the same path as any other — which is why
cleanup needs no special case for shutdown.  A handler tells a cancellation
from a real failure with `is-cancellation` and re-raises it rather than turning
it into a 500.

**Resource management** is scoped.  Outside tasks, `resource/scope` runs
release on success, failure and cancellation.  *Inside* a task, `finally`
cannot span a suspension point — when the scheduler captures a continuation and
returns without resuming, Koka treats the computation as abandoned and runs
`finally` immediately — so sockets use `runtime/task`'s `defer`, which releases
when the task really ends.  Database connections and statements are outside
that path and use `resource/scope` directly.

**Application services** are passed as plain values, not effects.  The database
handle is an argument.  An effect would have bought indirection without buying
anything testable: the store is already swappable by passing a different
connection, and the unit tests use `:memory:`.

## Limits

The transport limits are enforced while reading, so an oversized request is
refused before it is buffered:

| limit                | value  | exceeded |
| -------------------- | ------ | -------- |
| request line         | 8 KiB  | 414      |
| header block         | 16 KiB | 431      |
| header count         | 100    | 431      |
| request body         | 1 MiB  | 413      |
| reads per request    | 1024   | 408      |
| concurrent connections | 256  | connection not accepted |
| requests per connection | 100 | connection closed |
| request timeout      | 15 s   | 408      |
| idle keep-alive      | 30 s   | connection closed |

The parser limits are resource ceilings, checked while parsing. Exceeding one
is malformed input:

| limit                | value  | exceeded |
| -------------------- | ------ | -------- |
| JSON document        | 1 MiB  | 400      |
| JSON nesting depth   | 8      | 400      |
| JSON object members  | 32     | 400      |

The field limits are this API's own rules, checked after a document has parsed.
Exceeding one is a well-formed request we decline:

| limit                | value  | exceeded |
| -------------------- | ------ | -------- |
| title / body         | 200 / 10000 characters | 422 |
| page size            | 100 notes | (silently capped) |

The three tables are separate on purpose. Setting the parser ceiling to the
field limit collapsed the distinction, and a body of 10001 valid characters
came back as 400 "malformed JSON" rather than 422 "the body is too long".

## Known limitations

* Shutdown is driven by `NOTES_RUN_MS` rather than a signal; the runtime has no
  signal handling yet.
* IPv4 only.
* No TLS. Put a terminating proxy in front of it.
* No authentication, no pagination cursors, no partial updates.
* The task scheduler is cooperative: a handler that never suspends is not
  interrupted by cancellation.
