/* The HTTP surface: routes, codecs, and validation.

   Codecs are written by hand, in both directions.  There is no derivation:
   the wire format is part of the contract and should be visible.

   Errors are separated: anything the client got wrong is a 4xx with a JSON
   body naming the problem, and anything we got wrong is a 500 with a generic
   body and the detail in the log.  A client never sees an internal message.
*/
module notes/api

import bytes/bytes
import json/value
import json/parse
import sqlite/db
import http/message
import http/router
import logging/log
import runtime/task
import notes/store

// Conservative for a notes API: a title and a body, not a document store.
pub val title-limit : int = 200
pub val body-limit  : int = 10000
pub val page-size : int = 100

// The JSON parser's own limits.
//
// `max-bytes` and `max-string` are deliberately *not* the field limits.  A
// parser limit is a resource ceiling -- exceeding it is malformed input, 400.
// A field limit is a rule about this API -- exceeding it is a well-formed
// document that says something we will not store, 422.  Setting the parser
// ceiling to the field limit collapses the two, and a body of 10001 valid
// characters came back as "malformed JSON" instead of "the body is too long".
// So the parser is allowed everything the HTTP layer let through, and
// `validate` is what enforces the API's own rules.
val max-request-body : int = 1024 * 1024

val json-limits : parse/limits
  = parse/default-limits(max-bytes = max-request-body, max-depth = 8,
                         max-members = 32, max-string = max-request-body)

// ----------------------------------------------------------------------------
// codecs
// ----------------------------------------------------------------------------

pub fun note-json( n : note ) : json
  JsObject([ ("id",      JsInt(n.key))
           , ("title",   JsString(n.title))
           , ("body",    JsString(n.body))
           , ("created", JsInt(n.created)) ])

pub fun notes-json( ns : list<note> ) : json
  JsObject([ ("items", JsArray(ns.map(note-json)))
           , ("count", JsInt(ns.length)) ])

// What a create request must look like.  Every failure names the field.
pub fun decode-new-note( j : json ) : div either<string, (string, string)>
  match j
    JsObject(_) ->
      match (j.member("title"), j.member("body"))
        (Nothing, _) -> Left("'title' is required")
        (Just(t), mb) ->
          match t.as-string
            Nothing -> Left("'title' must be a string, not " ++ t.type-name)
            Just(title) ->
              val body = match mb
                           Nothing        -> Just("")
                           Just(JsString(s)) -> Just(s)
                           Just(_)        -> Nothing
              match body
                Nothing -> Left("'body' must be a string")
                Just(b) -> validate(title, b)
    _ -> Left("the request body must be a JSON object, not " ++ j.type-name)

fun validate( title : string, body : string ) : either<string, (string, string)>
  if title.trim.is-empty then Left("'title' must not be empty")
  elif title.count > title-limit then
    Left("'title' must be at most " ++ title-limit.show ++ " characters")
  elif body.count > body-limit then
    Left("'body' must be at most " ++ body-limit.show ++ " characters")
  else Right((title.trim, body))

// ----------------------------------------------------------------------------
// responses
// ----------------------------------------------------------------------------

fun ok-json( j : json ) : div response
  json-response(200, j.show)

fun created-json( j : json ) : div response
  json-response(201, j.show)

// A client error: the message is safe to show because we wrote it.
fun client-error( status : int, message : string ) : div response
  json-response(status, JsObject([("error", JsString(message))]).show)

// A server error: the client gets nothing specific, the log gets everything.
fun server-error() : div response
  json-response(500, "{\"error\":\"internal server error\"}")

// ----------------------------------------------------------------------------
// routes
// ----------------------------------------------------------------------------

// The routes are written against the `notes` effect, so this is the only place
// that knows the notes live in SQLite.  `unit-test.kk` calls the same handlers
// under `with-memory` and never opens a database.
pub fun routes( d : database ) : list<route<<async,logger|io>>>
  [ route("GET",    "/health",    fn(_r, _p) with-sqlite(d){ health() })
  , route("GET",    "/items",     fn(_r, _p) with-sqlite(d){ list-items() })
  , route("GET",    "/items/:id", fn(_r, p)  with-sqlite(d){ get-item(p) })
  , route("POST",   "/items",     fn(r,  _p) with-sqlite(d){ create-item(r) })
  , route("DELETE", "/items/:id", fn(_r, p)  with-sqlite(d){ delete-item(p) })
  ]

// ----------------------------------------------------------------------------
// handler steps
// ----------------------------------------------------------------------------

// A step in a handler: the value to carry on with, or the response to send
// instead of carrying on.
//
// `with x <- step.or-respond` is what lets a handler read as the sequence of
// checks it is.  Written with nested `match`, the same five checks nest five
// deep and the interesting line is the innermost one.
pub alias step<a> = either<response,a>

fun or-respond( s : step<a>, next : (a) -> <notes,async,logger|io> response )
    : <notes,async,logger|io> response
  match s
    Left(resp) -> resp
    Right(v)   -> next(v)

// The media type without its parameters: `text/plain; charset=utf-8` is
// `text/plain`.  Compared whole, so `application/jsonp` is not JSON.
fun media-type( ct : string ) : div string
  ct.split(";").head.default("").trim.to-lower

// The body as JSON, or the response saying why it is not.  A missing
// content-type is a 415; a body that does not parse is a 400.
fun json-body( r : request ) : div step<json>
  val declared = match r.header("content-type")
                   Just(ct) -> ct.media-type
                   Nothing  -> ""
  if declared != "application/json" then
    Left(client-error(415, "expected content-type: application/json"))
  else match parse(r.body, json-limits)
    Right(j) -> Right(j)
    Left(e)  -> Left(client-error(400, "malformed JSON: " ++ e.show))

// A well-formed document that this API declines is a 422, not a 400: the
// client's JSON was fine, its meaning was not.
fun new-note( j : json ) : div step<(string, string)>
  match decode-new-note(j)
    Right(tb) -> Right(tb)
    Left(msg) -> Left(client-error(422, msg))

// `strict-nat` rather than `parse-int`: the latter accepts `0x1`, `+1` and
// `1_0`, so `/items/0x1` would delete note 1 while reading as something else
// to any gateway in front of us.
fun note-id( p : params ) : div step<int>
  match p.param("id")
    Nothing -> Left(client-error(400, "missing id"))
    Just(s) ->
      match s.strict-nat
        Just(i) -> Right(i)
        Nothing -> Left(client-error(400, "id must be a decimal integer, got " ++ s.show))

// Run a store operation.  A cancellation is the server stopping and propagates;
// anything else is ours, so it is logged and answered with a 500 that says
// nothing about it.
fun attempt( action : () -> <notes,async,logger|io> a ) : <notes,async,logger|io> step<a>
  match try(action)
    Ok(v)     -> Right(v)
    Error(ex) ->
      if is-cancellation(ex) then throw-exn(ex)
      else
        error("request failed", [("error", ex.message)])
        Left(server-error())

// ----------------------------------------------------------------------------
// handlers
// ----------------------------------------------------------------------------

pub fun health() : <notes,async,logger|io> response
  // A health check that does not touch the store is not a health check.
  match try({ count-in-store() })
    Ok(n)     -> ok-json(JsObject([("status", JsString("ok")), ("notes", JsInt(n))]))
    Error(ex) ->
      error("health check failed", [("error", ex.message)])
      json-response(503, "{\"status\":\"unavailable\"}")

pub fun list-items() : <notes,async,logger|io> response
  with ns <- attempt({ list-from-store(page-size) }).or-respond
  ok-json(notes-json(ns))

pub fun get-item( p : params ) : <notes,async,logger|io> response
  with id <- p.note-id.or-respond
  with mb <- attempt({ fetch-from-store(id) }).or-respond
  match mb
    Just(n) -> ok-json(note-json(n))
    Nothing -> client-error(404, "no note with id " ++ id.show)

pub fun create-item( r : request ) : <notes,async,logger|io> response
  with j             <- r.json-body.or-respond
  with (title, body) <- new-note(j).or-respond
  with n             <- attempt({ create-in-store(title, body) }).or-respond
  created-json(note-json(n))

pub fun delete-item( p : params ) : <notes,async,logger|io> response
  with id      <- p.note-id.or-respond
  with removed <- attempt({ remove-from-store(id) }).or-respond
  if removed then response(204)
  else client-error(404, "no note with id " ++ id.show)
