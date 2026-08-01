# Linkdrop

Upload a file to storage you own, get a link you can paste anywhere.

A small Swift client for a "bring your own bucket" share service: your own
Cloudflare Worker in front of your own R2 bucket. No accounts, no third party,
no expiring links. The matching server is about 900 lines of TypeScript and
lives in [`Worker/`](../../Worker) of this repository.

```swift
import Linkdrop

let endpoint = LinkdropEndpoint(base: "s.example.com", token: token)!
let uploader = LinkdropUploader()

guard case .ok(let plan) = LinkdropGate.plan(image: fileURL) else { return }
let link = try await uploader.upload(plan, to: endpoint) { fraction in
    print("\(Int(fraction * 100))%")
}
print(link.pageURL)   // https://s.example.com/a7Kd9xQ2mZ01
```

- **macOS 13+ / iOS 16+**, Swift 6, no dependencies.
- Streams from disk. A 120 MB upload never becomes 120 MB of resident memory.
- Two routes, picked by size: one request for small files, a presigned PUT
  straight to object storage for anything a Worker's request body cannot hold.
- Errors are sentences, not codes.

## What each piece does

| | |
|---|---|
| `LinkdropEndpoint` | Where uploads go and what authorises them. Normalises the URL and **refuses plain http anywhere but loopback**, because the alternative is a bearer token in clear on the wire. |
| `LinkdropCredentials` | The token, in the Keychain. See the caveat below. |
| `LinkdropGate` | Whether a file can be shared, and cheap fixes when it cannot. Converts HEIC/TIFF/BMP to PNG; inspects a video's real codecs. |
| `LinkdropUploader` | The transfer. An actor; owns no UI. |
| `LinkdropError` | `.offline`, `.unauthorized`, `.unsupported(reason)` … each with a `message` worth showing and an `isRetryable` worth acting on. |

## The gate is the interesting part

"It opens here" and "it opens for the person you sent it to" are different
claims, and nothing on the sender's machine tells them apart. A HEIC still and
an HEVC recording both open instantly in Preview and QuickTime, and are both
unopenable for most of the people a link reaches.

```swift
switch await LinkdropGate.plan(video: url, duration: 12.5) {
case .ok(let plan):      try await uploader.upload(plan, to: endpoint)
case .refused(let why):  show(why)  // "This video is HEVC, which most browsers cannot play."
}
```

It reads the container's actual format descriptions rather than trusting the
recorder's settings — those are different facts and only one of them can be
checked.

## Things measured rather than assumed

**iCloud Keychain sync usually is not available.** `LinkdropCredentials` asks for
a synchronizable item by default and falls back to a local one. Measured on
macOS 26 with a Developer ID signature:

| keychain | synchronizable | result |
|---|---|---|
| legacy (file) | false | `errSecSuccess` |
| legacy (file) | true | **-34018** `errSecMissingEntitlement` |
| data protection | false | **-34018** |
| data protection | true | **-34018** |

Synchronizable items live only in the data-protection keychain, and reaching it
needs `com.apple.application-identifier` or the App Sandbox — restricted
entitlements that require a provisioning profile. Without the fallback, `save`
returns false, nothing is stored, and an app can go on believing it is
unconfigured while a "test connection" button that uses the token still in its
text field reports success. Ask `isSynchronized` before promising a user that
their other machine is already set up.

**Progress granularity depends on the network, not the implementation.** The same
120 MB upload produced 35 callbacks over the internet and a 3 MB one produced
exactly 1 over loopback — the kernel accepts a small body in a single write. A
test asserting "more than one callback" passes or fails on where the server is,
not on whether the file is being streamed.

## The server side

`Worker/` is the other half: a Cloudflare Worker over an R2 bucket, serving
range requests, an unfurlable preview page, and delete. The client speaks:

| | |
|---|---|
| `PUT /api/put?ext=…` | small files, one request |
| `POST /api/new` | large files; returns a presigned PUT URL |
| `PUT /api/poster/<key>` | a still for a video, so links unfurl with a thumbnail |
| `DELETE /api/o/<key>` | revoke |
| `GET /api/list` | recent uploads |

Any server with those five routes will do. Nothing here is Cloudflare-specific
except the README pointing at it.

## Licence

MIT.
