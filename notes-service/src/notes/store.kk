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

pub fun count-notes( d : database ) : io int
  match d.query-one("SELECT COUNT(*) AS n FROM notes")
    Just(r) -> r.int-at("n").default(0)
    Nothing -> 0

// Drop the `Nothing`s.  A row that does not decode is a schema bug, not a
// client error, so it is skipped rather than turned into a 500 -- the
// migration tests are what keep it from happening.
fun keep-just( xs : list<maybe<a>> ) : div list<a>
  xs.foldl([], keep-one)

fun keep-one( acc : list<a>, m : maybe<a> ) : list<a>
  match m
    Just(x) -> acc ++ [x]
    Nothing -> acc
