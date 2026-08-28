const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  _buildSocialPostDoc,
  _notificationReadPatch,
  _requireCreatePostDraft,
  _savedPostDoc,
} = require("../src/social");

test("social post draft requires authenticated owner storage path", () => {
  const draft = _requireCreatePostDraft({
    postId: "post_123",
    caption: "Hello Friendify",
    imageURL: "https://firebasestorage.googleapis.com/post.jpg",
    imagePath: "social_uploads/user_123/post_123.jpg",
    isStory: false,
  }, "user_123");

  assert.equal(draft.postId, "post_123");
  assert.equal(draft.caption, "Hello Friendify");
  assert.equal(draft.isStory, false);

  assert.throws(
    () => _requireCreatePostDraft({
      postId: "post_123",
      caption: "Hello Friendify",
      imageURL: "https://firebasestorage.googleapis.com/post.jpg",
      imagePath: "social_uploads/other_user/post_123.jpg",
      isStory: false,
    }, "user_123"),
    (err) => err && err.code === "invalid-argument" &&
      err.message === "invalid_image_path"
  );
});

test("social post builder uses server owner profile and zero counters", () => {
  const now = 1770000000000;
  const post = _buildSocialPostDoc({
    draft: {
      postId: "post_123",
      caption: "A post",
      imageURL: "https://example.com/post.jpg",
      imagePath: "social_uploads/user_123/post_123.jpg",
      isStory: false,
    },
    uid: "user_123",
    owner: {
      displayName: "Server Name",
      photoURL: "https://example.com/me.jpg",
    },
    now,
  });

  assert.equal(post.ownerId, "user_123");
  assert.equal(post.ownerName, "Server Name");
  assert.equal(post.caption, "A post");
  assert.equal(post.likeCount, 0);
  assert.equal(post.commentCount, 0);
  assert.equal(post.shareCount, 0);
  assert.equal(post.createdAtMs, now);
  assert.equal(post.expiresAtMs, 0);
});

test("saved post doc stores only bookmark fields", () => {
  const doc = _savedPostDoc("post_123", 1770000000000);
  assert.deepEqual(Object.keys(doc).sort(), [
    "postId",
    "savedAt",
    "savedAtMs",
  ]);
  assert.equal(doc.postId, "post_123");
  assert.equal(doc.savedAtMs, 1770000000000);
});

test("notification read patch only marks read metadata", () => {
  const patch = _notificationReadPatch(1770000000000);
  assert.deepEqual(Object.keys(patch).sort(), [
    "read",
    "readAt",
    "readAtMs",
  ]);
  assert.equal(patch.read, true);
  assert.equal(patch.readAtMs, 1770000000000);
});


// ---------- public review mirror writer contract ----------
// aggregateReviewToUser_v2 is a Firestore onCreate trigger, so its write is
// asserted here as a source contract: the mirror payload must be an explicit
// anonymous allowlist, never a spread of the client-authored review document.

function publicReviewMirrorWriteBlock() {
  const source = fs.readFileSync(
    path.join(__dirname, "..", "src", "triggers.js"),
    "utf8"
  );
  const start = source.indexOf('.collection("public_users")');
  assert.ok(start > -1, "public review mirror write must exist");
  const reviewsAt = source.indexOf('.collection("reviews")', start);
  assert.ok(reviewsAt > -1, "mirror must target the reviews subcollection");
  const setAt = source.indexOf(".set(", reviewsAt);
  assert.ok(setAt > -1, "mirror must perform a set()");

  // Bound the slice to the balanced set(...) call so the assertions cannot
  // read into unrelated code that follows this trigger.
  const open = source.indexOf("(", setAt);
  let depth = 0;
  let end = -1;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === "(") depth += 1;
    else if (source[i] === ")") {
      depth -= 1;
      if (depth === 0) {
        end = i + 1;
        break;
      }
    }
  }
  assert.ok(end > -1, "mirror set() call must be balanced");
  return source.slice(open, end);
}

test("public review mirror writes only the anonymous allowlisted schema", () => {
  const block = publicReviewMirrorWriteBlock();
  for (const field of ["stars", "comment", "createdAt", "createdAtMs"]) {
    assert.ok(block.includes(field), `mirror must write ${field}`);
  }
});

test("public review mirror never writes identifying or private fields", () => {
  const block = publicReviewMirrorWriteBlock();
  const forbidden = [
    "reviewerId",
    "reviewedUserId",
    "uid",
    "email",
    "phone",
    "callId",
    "chatSessionId",
    "sessionId",
    "ip",
    "device",
    "invalidReason",
    "aggregationSkipped",
    "amount",
    "paymentId",
    "orderId",
  ];
  for (const field of forbidden) {
    assert.ok(
      !block.includes(field),
      `mirror must not write forbidden field ${field}`
    );
  }
});

test("public review mirror cannot copy client-supplied extra fields", () => {
  const block = publicReviewMirrorWriteBlock();
  // A spread of the source review document would leak arbitrary client fields.
  assert.ok(!block.includes("...data"), "mirror must not spread review data");
  assert.ok(!block.includes("...snap"), "mirror must not spread the snapshot");
  assert.ok(
    !/\.\.\.[A-Za-z_$]/.test(block),
    "mirror payload must not use any spread"
  );
  // The comment is sanitized and length-capped rather than passed through raw.
  assert.ok(block.includes("slice("), "comment must be length-capped");
});
