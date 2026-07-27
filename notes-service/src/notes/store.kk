/* Persistence for notes.

   Every statement is prepared and parameterised; no SQL is ever built by
   concatenating a value.  Every query runs inside a scope that finalises its
   statement, and every write runs inside a transaction that rolls back on
   failure or cancellation.
*/
module notes/store

import sqlite/db

pub struct note
  key     : int
  title   : string
  body    : string
  // seconds since the epoch, as SQLite's strftime gives them
  created : int

// The schema, as migrations.  Ids are stable and increasing; adding a step
// means appending to this list, never editing an existing one.
pub val schema : list<migration>
  = [ Migration(1, "create notes",
        "CREATE TABLE notes (" ++
        "  id      INTEGER PRIMARY KEY AUTOINCREMENT," ++
        "  title   TEXT    NOT NULL," ++
        "  body    TEXT    NOT NULL," ++
        "  created INTEGER NOT NULL" ++
        ")")
    , Migration(2, "index notes by creation time",
        "CREATE INDEX notes_created ON notes (created DESC)")
    ]

// A migration that throws would otherwise strand the connection it was handed:
// nothing else holds it, and sqlite will not close it for us.
pub fun open-store( path : string ) : io database
  val d = db/open(path)
  match try({ migrate(d, schema) })
    Ok(_)     -> d
    Error(ex) -> { d.close; throw-exn(ex) }

pub fun with-store( path : string, action : (database) -> io a ) : io a
  with-database(path) fn(d)
    migrate(d, schema)
    action(d)

// ----------------------------------------------------------------------------
// queries
// ----------------------------------------------------------------------------

fun to-note( r : row ) : div maybe<note>
  match (r.int-at("id"), r.text-at("title"), r.text-at("body"), r.int-at("created"))
    (Just(i), Just(t), Just(b), Just(c)) -> Just(Note(i, t, b, c))
    _ -> Nothing

// Newest first, bounded.  The bound is the API's page size, not a suggestion:
// a table with a million rows must not turn into a million-element list.
pub fun list-notes( d : database, limit : int = 100 ) : io list<note>
  d.query("SELECT id, title, body, created FROM notes ORDER BY created DESC, id DESC LIMIT ?",
          [SqlInt(limit)], limit + 1)
   .map(to-note).keep-just

pub fun get-note( d : database, id : int ) : io maybe<note>
  match d.query-one("SELECT id, title, body, created FROM notes WHERE id = ?", [SqlInt(id)])
    Nothing -> Nothing
    Just(r) -> to-note(r)

// Insert and return the stored row, so the caller sees exactly what was saved
// (including the id and timestamp the database chose).
pub fun create-note( d : database, title : string, body : string ) : io note
  with-transaction(d) fn()
    d.run("INSERT INTO notes (title, body, created) VALUES (?, ?, strftime('%s','now'))",
          [SqlText(title), SqlText(body)])
    val id = d.last-insert-id
    match get-note(d, id)
      Just(n) -> n
      Nothing -> throw("the note that was just inserted could not be read back")

// True if a row was removed.
pub fun delete-note( d : database, id : int ) : io bool
  with-transaction(d) fn()
    d.run("DELETE FROM notes WHERE id = ?", [SqlInt(id)])
    d.changes > 0

// `COUNT(*)` always returns one integer row, so anything else is a broken
// schema rather than an empty table.  Answering 0 would make the health check
// report success for exactly the condition it exists to catch.
pub fun count-notes( d : database ) : io int
  match d.query-one("SELECT COUNT(*) AS n FROM notes")
    Just(r) ->
      match r.int-at("n")
        Just(n)  -> n
        Nothing  -> throw("the note count did not come back as an integer")
    Nothing -> throw("counting notes returned no row")

// Drop the `Nothing`s.  A row that does not decode is a schema bug, not a
// client error, so it is skipped rather than turned into a 500 -- the
// migration tests are what keep it from happening.
//
// Written with `filter-map` rather than a fold that appends: `acc ++ [x]`
// copies the accumulator once per row, which is O(n^2) over a page.
fun keep-just( xs : list<maybe<a>> ) : list<a>
  xs.filter-map(fn(m) m)

// ----------------------------------------------------------------------------
// the store as an effect
//
// The handlers above talk to SQLite.  The routes do not: they are written
// against this effect, and the wiring decides what it means.  `with-sqlite`
// is what the service installs; `with-memory` is what the tests install, and
// it touches no file, no database and no clock.
//
// That is the point of an effect here rather than a `:database` argument.  A
// connection argument makes the store swappable for *another database*; an
// effect makes it swappable for something that is not a database at all, so
// the HTTP surface -- routing, status codes, validation, JSON -- can be tested
// without one.
// ----------------------------------------------------------------------------

pub effect notes
  fun create-in-store( title : string, body : string ) : note
  fun fetch-from-store( id : int ) : maybe<note>
  fun list-from-store( limit : int ) : list<note>
  fun remove-from-store( id : int ) : bool
  fun count-in-store() : int

// Serve the effect from a SQLite connection.
pub fun with-sqlite( d : database, action : () -> <notes,io|e> a ) : <io|e> a
  with handler
    fun create-in-store(t, b)  create-note(d, t, b)
    fun fetch-from-store(id)   get-note(d, id)
    fun list-from-store(n)     list-notes(d, n)
    fun remove-from-store(id)  delete-note(d, id)
    fun count-in-store()       count-notes(d)
  action()

// Serve the effect from a list held in memory.
//
// Ids count from one and `created` counts from a fixed instant, so a test
// asserting on either gets the same answer on every machine and every run --
// which the SQLite handler, taking its timestamps from the clock, cannot give.
pub val memory-epoch : int = 1700000000

pub fun with-memory( seed : list<note> = [], action : () -> <notes|e> a ) : e a
  var rows := seed
  var next := seed.foldl(0, fn(m, n) max(m, n.key)) + 1
  with handler
    fun create-in-store(t, b)
      val n = Note(next, t, b, memory-epoch + next)
      rows := Cons(n, rows)
      next := next + 1
      n
    fun fetch-from-store(id)
      rows.find(fn(n) n.key == id)
    fun list-from-store(limit)
      // newest first, as the SQL does
      rows.take(limit)
    fun remove-from-store(id)
      val before = rows.length
      rows := rows.filter(fn(n) n.key != id)
      rows.length < before
    fun count-in-store()
      rows.length
  action()
