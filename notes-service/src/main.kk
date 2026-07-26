/* The notes service.

   Reads its configuration from the environment, opens the database, applies
   migrations, and serves until stopped.

   Configuration (all optional):

     NOTES_HOST     bind address              (default 127.0.0.1)
     NOTES_PORT     port, 0 for any free one  (default 8080)
     NOTES_DB       database file             (default notes.db)
     NOTES_LOG      debug|info|warn|error     (default info)
     NOTES_RUN_MS   stop after this many ms   (default 0, meaning run forever)

   `NOTES_RUN_MS` exists so the integration tests can start a real server,
   exercise it, and have it shut down on its own rather than being killed --
   which is what makes "shuts down gracefully" testable.
*/
import std/os/env
import sqlite/db
import http/message
import http/server
import logging/log
import runtime/task
import notes/store
import notes/api

fun env-or( name : string, fallback : string ) : io string
  match get-env-value(name)
    Just(v) | v.is-notempty -> v
    _ -> fallback

fun env-int( name : string, fallback : int ) : io int
  env-or(name, "").parse-int.default(fallback)

fun level-of( s : string ) : level
  match s.to-lower
    "debug" -> Debug
    "warn"  -> Warn
    "error" -> Error
    _       -> Info

fun main()
  val host    = env-or("NOTES_HOST", "127.0.0.1")
  val port    = env-int("NOTES_PORT", 8080)
  val db-path = env-or("NOTES_DB", "notes.db")
  val level   = level-of(env-or("NOTES_LOG", "info"))
  val run-ms  = env-int("NOTES_RUN_MS", 0)

  // The database is opened once and shared by every request: the runtime is
  // single threaded, so a connection is used by one task at a time and a pool
  // would buy nothing.
  with-store(db-path) fn(d)
    val cfg  = default-config(host = host, port = port)
    val logs = default-log-config(min = level,
                                  base = [("service", "notes"), ("db", db-path)])
    serve-routes(routes(d), fn(srv) wait-then-stop(srv, run-ms), cfg, logs)

// Run until the deadline, or forever when there is none.
//
// A real deployment would stop on SIGTERM; that needs a signal handler in the
// runtime, which this program does not have, so the time bound is what makes
// shutdown exercisable.  Either way `serve` cancels in-flight work and waits
// for it before returning.
fun wait-then-stop( srv : server, run-ms : int ) : <async|io> ()
  if run-ms <= 0 then sleep-forever()
  else
    sleep(run-ms)
    srv.stop

fun sleep-forever() : <async|io> ()
  sleep(3600000)
  sleep-forever()
