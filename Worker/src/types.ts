export interface Env {
  BUCKET: R2Bucket;

  /// The one credential the DuoShot client holds. A leaked copy can upload and
  /// delete, but cannot read the bucket outside this Worker's routes and cannot
  /// touch any other bucket -- which is the entire reason the client does not
  /// get R2 S3 credentials instead.
  UPLOAD_TOKEN: string;

  /// Origin the returned links are built from, no trailing slash.
  /// e.g. "https://s.example.com"
  PUBLIC_BASE: string;

  /// Only needed for POST /api/new, which hands the client a presigned PUT so
  /// large recordings never pass through this Worker (and so never meet the
  /// Workers request-body limit). Leave unset to run upload-through-Worker only.
  R2_ACCOUNT_ID?: string;
  R2_ACCESS_KEY_ID?: string;
  R2_SECRET_ACCESS_KEY?: string;
  /// The bucket's real name, needed to build the S3 path. The binding above
  /// does not expose it.
  R2_BUCKET_NAME?: string;
}

/// The sidecar record, stored at `m/<key>` as JSON.
///
/// Separate from the uploaded object on purpose: with a presigned PUT the bytes
/// go straight to R2 and this Worker never sees them, so anything it needs to
/// know later has to be written at creation time. It also survives the object,
/// which is what lets an expired link answer 410 instead of 404.
export interface ShareRecord {
  key: string;
  /// Where the bytes live: "p/<key>" (kept) or "e/<key>" (lifecycle-expired).
  objectKey: string;
  /// Lowercase, no dot. The served Content-Type is derived from THIS through a
  /// fixed allowlist, never from whatever the uploader declared.
  ext: string;
  /// Display only. Never used to build a path.
  name: string;
  size: number | null;
  kind: "image" | "video" | "file";
  width?: number;
  height?: number;
  /// Seconds.
  duration?: number;
  /// Object key of a poster still for a video, if one was uploaded. This is
  /// what makes a video link unfurl with a thumbnail in chat apps.
  posterKey?: string;
  createdAt: string;
  ephemeral: boolean;
  /// One read and the bytes are deleted. Images only: a video is fetched with
  /// Range requests, so "the first complete read" is not a moment that exists
  /// for one, and a link that burned halfway through a seek would be a lie.
  burn?: boolean;
  /// Set when the read happened. Its presence is what turns this record into a
  /// tombstone -- the object and everything describing it are gone by then, and
  /// all that is left is enough to answer "you already opened this" instead of
  /// the 404 a deleted sidecar would give.
  burnedAt?: string;
}
