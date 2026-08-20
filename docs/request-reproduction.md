# Request reproduction

> Something calls this Rails endpoint. What request do I send to exercise the same behavior?

That is the whole question this answers. A Jira story says an external system
`POST`s to `/api/v1/inspections`; the endpoint exists, someone else built it,
and reproducing it locally normally means reading routes, controllers,
`before_action` filters, and old specs until you can guess a working request.

Karst answers it the same way it answers every other question: by running the
real application and reporting what actually happened.

## What it is

You give Karst a method, a path, and (for a body-carrying method) a body.
Karst issues **exactly one** request through the real Rails stack, inside a
rolled-back database transaction, and reports:

- the controller and action that actually dispatched
- the route parameters the router actually bound
- the halted callback, if a `before_action` stopped the request
- any raised exception
- the response status and content type
- how many database writes the request made
- a **cURL command for exactly what Karst sent**

Then you iterate. A first attempt that halts at `authenticate_api_key!` has
told you the endpoint's real gate. Add the header, send again, get a `201`,
and copy the cURL — which is now a command you have watched work, not one
assembled from reading code.

## This is observed behavior, not documentation

Karst observes the requests it issues. It does not record your application's
production traffic, and it never infers a request from routes, controller
source, or strong-parameter declarations.

The practical consequence: Karst can tell you **whether the request you
described works, and what it did**, but it cannot invent a body it has never
seen. What it removes is the two genuinely hard parts — knowing whether a
request works, and knowing what stopped it when it doesn't.

A field Karst could not observe is `null` and is named in `unobserved`, never
filled in with a plausible-looking value. If the path did not route, Karst
reports no controller rather than guessing one.

### What Karst deliberately does not capture

- **Your application's real traffic.** Karst installs no request recorder and
  keeps no buffer of past requests. There is nothing to leak later, and
  nothing running on an ordinary request.
- **How an external client authenticates.** Karst can sign in as one of your
  own existing users, and it reports the callback that halted a request — but
  it never claims to know that an endpoint "uses an API key". The halted
  callback's name is evidence; anything beyond it would be a guess.
- **Response bodies.** Karst reports the response status and content type,
  never the body.

## Secrets

A generated request that makes you fill in a credential is better than one
that leaks one, so Karst always chooses the former.

- **Parameters** pass through your application's own
  `config.filter_parameters`, using Rails' own `ActiveSupport::ParameterFilter`
  — the same rules, including nested hashes and Procs, that already keep those
  values out of your logs. Karst then applies one additional, conservative
  credential-name filter on top (`token`, `secret`, `api_key`, `password`,
  `signature`, `session`, ...), because an application's `filter_parameters` is
  tuned for its own logs and routinely misses credentials that only appear in a
  third-party integration's payload.
- **Headers** are handled by name, never by value. `Authorization`, `Cookie`,
  `X-Api-Key`, `X-CSRF-Token` and friends become `<AUTH_TOKEN>`,
  `<SESSION_COOKIE>`, `<API_KEY>`, `<CSRF_TOKEN>`. Their real values are never
  read, compared, or echoed. Headers that describe a request rather than
  authorize it (`Content-Type`, `Accept`, ...) are shown as sent; anything else
  whose name looks credential-shaped becomes `<FILTERED>`.
- **Credentials in the path** — a password-reset token, a signed id — are
  substituted back out of the URL too, so `/reset/s3cret` becomes
  `/reset/<TOKEN>` in both the recipe and the cURL command.
- **A body Karst cannot parse** (anything but JSON or form encoding) is sent
  as given but never echoed back; the command shows `<BODY>`.
- **Nothing is persisted.** Karst writes no recipe, request, or credential to
  disk, and `/karst` is served `no-store`.

One deliberate exception, for usability: the `/karst` form re-fills the body
and header boxes with what you just typed, so you can edit and resend. That is
ordinary form behavior on your own machine — but it does mean a credential you
paste there is visible on that page until you navigate away. The **recipe**
Karst generates, which is the part you copy into a ticket, never contains one.

## Reproducing a request

### At `/karst`

Open `/karst`, pick a URL, and expand **Reproduce request**. Fill in method,
path, content type, body, and any headers, then press **Send once and build
request**. The recipe appears below, ending in a copyable cURL command built
against your own development origin.

### From the shell

```bash
bin/rails karst:reproduce POST /api/v1/inspections \
  --content-type application/json \
  --body '{"serial_number":"ABC123","status":"passed"}' \
  --header 'Authorization: Bearer real-key'
```

Add `--json` for the same schema-versioned evidence document the MCP tool
returns. `--anonymous` sends without assuming any identity. Exit code `0`
means Karst observed a response, `1` means the request raised, `2` means Karst
could not issue it at all.

### From a coding agent

The MCP server exposes `reproduce_request(path:, method:, body:, content_type:,
headers:, anonymous:, base_url:)`. It returns the same document as `--json`:
request, identity, execution, response, `unobserved`, isolation, and the cURL
command.

It is a second tool rather than a mode of `verify_access` because the two have
different blast radii. `verify_access` answers "which existing user can reach
this page" by issuing up to 25 bounded GET requests automatically, and is
GET-only for a reason: running a mutating method as 25 users would mean 25
real creates, 25 enqueued jobs, and 25 delivered mails. `reproduce_request`
issues exactly one request that the caller fully specified.

## Identity

By default Karst sends the request as one existing user drawn from your
application's own configured principal source — the same machinery `/karst`
uses to answer "who can use this?", so you do not have to know how your app
signs anyone in. Pass `--anonymous` (or `anonymous: true`) to send with no
identity at all, which is usually what you want for an endpoint an external
system calls.

Karst reports which identity it assumed. It does not claim that is how the
external caller authenticates.

## Limitations

- **Same-connection rollback is not side-effect isolation.** Database writes on
  the request's own connection are rolled back. Background jobs, mail, outbound
  HTTP, files, Redis, and other database connections are not. One `POST` that
  enqueues a job really enqueues it. This is the same boundary the access sweep
  documents, and it is why reproduction issues exactly one request and never a
  sweep.
- **Development only.** Reproduction refuses to run outside
  `Rails.env.development?`, refuses when `config.enabled` is false, and at
  `/karst` requires a loopback peer, a same-origin POST, and Karst's own CSRF
  token.
- **Local paths only.** A target with a scheme, a host, or a leading `//` is
  refused rather than normalized.
- **`GET HEAD POST PUT PATCH DELETE` only.** Anything else is refused rather
  than passed through.
- **Header names must be header names.** A name outside `[A-Za-z0-9-]+`, or a
  CGI variable such as `REQUEST_METHOD` or `PATH_INFO`, is refused. Those
  would be written into the Rack environment rather than sent as headers, so
  the request Karst issued would stop matching the request Karst reports.
- **Multipart bodies are not parsed.** They are sent as given and shown as
  `<BODY>`.
- **Karst cannot invent a body.** If nothing has ever told you what the
  external system sends, Karst will faithfully report that your guess returned
  a `422` — which is still more than reading the controller gives you, but it
  is not the payload.

This is not API documentation, an OpenAPI generator, a request collection, or
an HTTP client. It makes one workflow easier: reproducing a request the
application actually handles.
