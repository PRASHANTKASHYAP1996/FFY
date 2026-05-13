const test = require("node:test");
const assert = require("node:assert/strict");

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
