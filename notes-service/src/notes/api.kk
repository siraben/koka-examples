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

// The JSON parser's own limits, scaled to what a note may contain.
val json-limits : parse/limits
  = parse/default-limits(max-bytes = body-limit + title-limit + 1024,
                         max-depth = 8, max-members = 32, max-string = body-limit)

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
// handlers
// ----------------------------------------------------------------------------

pub fun routes( d : database ) : list<route<<async,logger|io>>>
  [ route("GET",    "/health",    fn(_r, _p) health(d))
  , route("GET",    "/items",     fn(_r, _p) list-items(d))
  , route("GET",    "/items/:id", fn(_r, p)  get-item(d, p))
  , route("POST",   "/items",     fn(r,  _p) create-item(d, r))
  , route("DELETE", "/items/:id", fn(_r, p)  delete-item(d, p))
  ]

fun health( d : database ) : <async,logger|io> response
  // A health check that does not touch the database is not a health check.
  match try({ count-notes(d) })
    Ok(n)     -> ok-json(JsObject([("status", JsString("ok")), ("notes", JsInt(n))]))
    Error(ex) ->
      error("health check failed", [("error", ex.message)])
      json-response(503, "{\"status\":\"unavailable\"}")

fun list-items( d : database ) : <async,logger|io> response
  match try({ list-notes(d, page-size) })
    Ok(ns)    -> ok-json(notes-json(ns))
    Error(ex) -> report(ex)

fun get-item( d : database, p : params ) : <async,logger|io> response
  match parse-id(p)
    Left(msg) -> client-error(400, msg)
    Right(id) ->
      match try({ get-note(d, id) })
        Error(ex)      -> report(ex)
        Ok(Nothing)    -> client-error(404, "no note with id " ++ id.show)
        Ok(Just(n))    -> ok-json(note-json(n))

fun create-item( d : database, r : request ) : <async,logger|io> response
  // The server has already enforced the body size limit; this is the content
  // check, which is a different thing.
  match r.header("content-type")
    Just(ct) | !ct.to-lower.contains("application/json") ->
      client-error(415, "expected content-type: application/json")
    _ ->
      match parse(r.body, json-limits)
        Left(e)  -> client-error(400, "malformed JSON: " ++ e.show)
        Right(j) ->
          match decode-new-note(j)
            Left(msg) -> client-error(422, msg)
            Right((title, body)) ->
              match try({ create-note(d, title, body) })
                Ok(n)     -> created-json(note-json(n))
                Error(ex) -> report(ex)

fun delete-item( d : database, p : params ) : <async,logger|io> response
  match parse-id(p)
    Left(msg) -> client-error(400, msg)
    Right(id) ->
      match try({ delete-note(d, id) })
        Error(ex)   -> report(ex)
        Ok(True)    -> response(204)
        Ok(False)   -> client-error(404, "no note with id " ++ id.show)

fun parse-id( p : params ) : div either<string, int>
  match p.param("id")
    Nothing -> Left("missing id")
    Just(s) ->
      match s.parse-int
        Nothing -> Left("id must be an integer, got " ++ s.show)
        Just(i) -> if i < 0 then Left("id must not be negative") else Right(i)

// Turn an exception into a response.  A cancellation is the server shutting
// down and must propagate; anything else is ours and is logged, not shown.
fun report( ex : exception ) : <async,logger|io> response
  if is-cancellation(ex) then throw-exn(ex)
  else
    error("request failed", [("error", ex.message)])
    server-error()
