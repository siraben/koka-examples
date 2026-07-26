import kktest/assert
import kktest/runner
import kktest/tmp
import json/value
import json/parse
import sqlite/db
import http/message
import http/router
import notes/store
import notes/api

fun mem( action : (database) -> io a ) : io a
  with-database(":memory:") fn(d)
    migrate(d, schema)
    action(d)

fun decoded( text : string ) : div string
  match parse-string(text)
    Left(e)  -> "parse: " ++ e.message
    Right(j) ->
      match decode-new-note(j)
        Left(msg)      -> "reject: " ++ msg
        Right((t, b))  -> "ok:" ++ t ++ "|" ++ b

fun main()
  run-tests([
    group("codecs", [
      test("a note renders with every field", fn()
        val j = note-json(Note(7, "t", "b", 100))
        assert-equal(j.show, "{\"id\":7,\"title\":\"t\",\"body\":\"b\",\"created\":100}")
      ),
      test("a list renders with a count", fn()
        val j = notes-json([Note(1,"a","",1), Note(2,"b","",2)])
        assert-true(j.show.starts-with("{\"items\":[").bool, j.show)
        assert-true(j.show.contains("\"count\":2"), j.show)
      ),
      test("quotes and newlines in content are escaped", fn()
        val j = note-json(Note(1, "a\"b", "c\nd", 0))
        assert-true(j.show.contains("a\\\"b"), j.show)
        assert-true(j.show.contains("c\\nd"), j.show)
      ),
    ]),

    group("validation", [
      test("a well-formed body is accepted", fn()
        assert-equal(decoded("{\"title\":\"t\",\"body\":\"b\"}"), "ok:t|b")
      ),
      test("body defaults to empty", fn()
        assert-equal(decoded("{\"title\":\"t\"}"), "ok:t|")
      ),
      test("a missing title is rejected", fn()
        assert-true(decoded("{\"body\":\"b\"}").contains("'title' is required"))
      ),
      test("an empty or blank title is rejected", fn()
        assert-true(decoded("{\"title\":\"\"}").contains("must not be empty"))
        assert-true(decoded("{\"title\":\"   \"}").contains("must not be empty"))
      ),
      test("titles are trimmed", fn()
        assert-equal(decoded("{\"title\":\"  t  \",\"body\":\"b\"}"), "ok:t|b")
      ),
      test("wrong types are rejected by name", fn()
        assert-true(decoded("{\"title\":5}").contains("'title' must be a string"))
        assert-true(decoded("{\"title\":\"t\",\"body\":5}").contains("'body' must be a string"))
      ),
      test("a non-object body is rejected", fn()
        assert-true(decoded("[1,2]").contains("must be a JSON object"))
        assert-true(decoded("\"hi\"").contains("must be a JSON object"))
      ),
      test("over-long fields are rejected", fn()
        val long = "{\"title\":\"" ++ "a".repeat(title-limit + 1) ++ "\"}"
        assert-true(decoded(long).contains("at most"))
      ),
      test("malformed json is reported as such", fn()
        assert-true(decoded("{").contains("parse:"))
      ),
    ]),

    group("store", [
      test("create then read back", fn()
        mem fn(d)
          val n = create-note(d, "t", "b")
          assert-equal(n.title, "t")
          assert-true(n.key > 0)
          assert-true(n.created > 1577836800, "timestamp looks wrong: " ++ n.created.show)
          match get-note(d, n.key)
            Just(n2) -> assert-equal(n2.title, "t")
            Nothing  -> assert-fail("the note was not stored")
      ),
      test("listing is newest first", fn()
        mem fn(d)
          val a = create-note(d, "a", "")
          val b = create-note(d, "b", "")
          val ids = list-notes(d).map(fn(n) n.key)
          assert-equal(ids.show, [b.key, a.key].show)
      ),
      test("listing is bounded", fn()
        mem fn(d)
          var i := 0
          while { i < 10 }
            create-note(d, "n" ++ i.show, "")
            i := i + 1
          assert-equal(list-notes(d, 3).length, 3)
      ),
      test("missing ids read as Nothing", fn()
        mem fn(d)
          assert-true(get-note(d, 999).is-nothing)
      ),
      test("delete reports whether it removed anything", fn()
        mem fn(d)
          val n = create-note(d, "t", "")
          assert-true(delete-note(d, n.key))
          assert-false(delete-note(d, n.key))
          assert-true(get-note(d, n.key).is-nothing)
      ),
      test("counting", fn()
        mem fn(d)
          assert-equal(count-notes(d), 0)
          create-note(d, "a", "")
          create-note(d, "b", "")
          assert-equal(count-notes(d), 2)
      ),
      test("content with quotes and unicode survives a round trip", fn()
        mem fn(d)
          val weird = "a\"b'c\n世界"
          val n = create-note(d, weird, weird)
          match get-note(d, n.key)
            Just(n2) ->
              assert-equal(n2.title, weird)
              assert-equal(n2.body, weird)
            Nothing -> assert-fail("not stored")
      ),
      test("a value that looks like SQL is stored, not executed", fn()
        mem fn(d)
          create-note(d, "x'); DROP TABLE notes; --", "")
          assert-equal(count-notes(d), 1)
          // the table is still there
          create-note(d, "still working", "")
          assert-equal(count-notes(d), 2)
      ),
    ]),

    group("migrations", [
      test("applied once, and again is a no-op", fn()
        mem fn(d)
          assert-equal(migrate(d, schema).length, 0, "the schema was applied twice")
      ),
      test("a fresh database gets the whole schema", fn()
        with-temp-dir fn(dir)
          with-database(dir ++ "/fresh.db") fn(d)
            assert-equal(migrate(d, schema).length, schema.length)
            create-note(d, "works", "")
            assert-equal(count-notes(d), 1)
      ),
      test("data survives reopening", fn()
        with-temp-dir fn(dir)
          val path = dir ++ "/persist.db"
          with-store(path) fn(d) create-note(d, "kept", "body")
          with-store(path) fn(d)
            assert-equal(count-notes(d), 1)
            assert-equal(list-notes(d).head.default(Note(0,"","",0)).title, "kept")
      ),
    ]),

    group("resource cleanup", [
      test("requests leave no statements open", fn()
        mem fn(d)
          val before = open-statements()
          create-note(d, "a", "")
          list-notes(d)
          get-note(d, 1)
          delete-note(d, 1)
          count-notes(d)
          assert-equal(open-statements(), before, "a store operation leaked a statement")
      ),
      test("a failed operation leaves no statements open", fn()
        mem fn(d)
          val before = open-statements()
          assert-throws({ d.query("SELECT * FROM nope") })
          assert-equal(open-statements(), before)
      ),
      test("many operations do not accumulate handles", fn()
        mem fn(d)
          val before = open-statements()
          var i := 0
          while { i < 300 }
            create-note(d, "n" ++ i.show, "")
            list-notes(d, 5)
            i := i + 1
          assert-equal(open-statements(), before)
      , timeout-s = 120),
    ]),

    group("routing", [
      test("every documented endpoint is routed", fn()
        mem fn(d)
          val rs = routes(d)
          assert-true(route-match(rs, "GET", "/health").is-matched)
          assert-true(route-match(rs, "GET", "/items").is-matched)
          assert-true(route-match(rs, "POST", "/items").is-matched)
          assert-true(route-match(rs, "GET", "/items/1").is-matched)
          assert-true(route-match(rs, "DELETE", "/items/1").is-matched)
      ),
      test("unknown paths and methods are not routed", fn()
        mem fn(d)
          val rs = routes(d)
          assert-false(route-match(rs, "GET", "/nope").is-matched)
          assert-false(route-match(rs, "PUT", "/items").is-matched)
      ),
    ]),
  ])
