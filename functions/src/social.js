const {
  admin,
  functions,
  REGION,
  assertCallableAppCheck,
  strOr,
  logEvent,
  deleteStoragePathIfSafe,
  deleteCollectionGroupDocsByField,
  reviewReportsForDeletedPost,
  reviewReportsForDeletedComment,
} = require("./shared");

const SOCIAL_POSTS = "social_posts";
const SOCIAL_LIKES = "likes";
const SOCIAL_COMMENTS = "comments";
const SOCIAL_SHARES = "shares";
const SOCIAL_SUBCOLLECTIONS = [SOCIAL_LIKES, SOCIAL_COMMENTS, SOCIAL_SHARES];
const SAVED_POSTS = "saved_posts";
const NOTIFICATIONS = "notifications";
const MAX_POST_CAPTION_LENGTH = 180;
const MAX_COMMENT_LENGTH = 500;
const MAX_REPORT_REASON_LENGTH = 1000;
const MAX_MARK_NOTIFICATIONS_READ = 100;

function requireUid(context) {
  const uid = strOr(context && context.auth && context.auth.uid).trim();
  if (!uid) {
    throw new functions.https.HttpsError("unauthenticated", "auth_required");
  }
  return uid;
}

function requirePostId(data) {
  const postId = strOr(data && data.postId).trim();
  if (!postId || postId.includes("/") || postId.length > 128) {
    throw new functions.https.HttpsError("invalid-argument", "invalid_post_id");
  }
  return postId;
}

function requireCreatePostDraft(data, uid) {
  const postId = requirePostId(data);
  const caption = strOr(data && data.caption).trim();
  const imageURL = strOr(data && data.imageURL).trim();
  const imagePath = strOr(data && data.imagePath).trim();
  const isStory = data && data.isStory === true;
  const expectedImagePath = `social_uploads/${uid}/${postId}.jpg`;

  // Stories were dropped from the product (feed/profile posts only).
  if (isStory) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "stories_disabled"
    );
  }

  if (!imageURL || !/^https?:\/\//.test(imageURL)) {
    throw new functions.https.HttpsError("invalid-argument", "invalid_image");
  }
  if (imagePath !== expectedImagePath) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "invalid_image_path"
    );
  }
  if (!isStory && !caption) {
    throw new functions.https.HttpsError("invalid-argument", "caption_required");
  }
  if (caption.length > MAX_POST_CAPTION_LENGTH) {
    throw new functions.https.HttpsError("invalid-argument", "caption_too_long");
  }

  return { postId, caption, imageURL, imagePath, isStory };
}

function buildSocialPostDoc({ draft, uid, owner, now }) {
  return {
    postId: draft.postId,
    ownerId: uid,
    ownerName: strOr(owner && owner.displayName, "Friend").trim() || "Friend",
    ownerPhotoURL: strOr(owner && owner.photoURL).trim(),
    caption: draft.isStory ? "Story" : draft.caption,
    imageURL: draft.imageURL,
    imagePath: draft.imagePath,
    isStory: draft.isStory,
    likeCount: 0,
    commentCount: 0,
    shareCount: 0,
    createdAtMs: now,
    expiresAtMs: draft.isStory ? now + 24 * 60 * 60 * 1000 : 0,
  };
}

function requireCommentText(data) {
  const text = strOr(data && data.text).trim();
  if (!text) {
    throw new functions.https.HttpsError("invalid-argument", "comment_required");
  }
  if (text.length > MAX_COMMENT_LENGTH) {
    throw new functions.https.HttpsError("invalid-argument", "comment_too_long");
  }
  return text;
}

function requireCommentId(data) {
  const commentId = strOr(data && data.commentId).trim();
  if (!commentId || commentId.includes("/") || commentId.length > 128) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "invalid_comment_id"
    );
  }
  return commentId;
}

function requireNotificationId(data) {
  const notificationId = strOr(data && data.notificationId).trim();
  if (
    !notificationId ||
    notificationId.includes("/") ||
    notificationId.length > 128
  ) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "invalid_notification_id"
    );
  }
  return notificationId;
}

function requireReportReason(data) {
  const reason = strOr(data && data.reason).trim();
  if (!reason) {
    throw new functions.https.HttpsError("invalid-argument", "reason_required");
  }
  if (reason.length > MAX_REPORT_REASON_LENGTH) {
    throw new functions.https.HttpsError("invalid-argument", "reason_too_long");
  }
  return reason;
}

function postRefFor(postId) {
  return admin.firestore().collection(SOCIAL_POSTS).doc(postId);
}

function savedPostRefFor(uid, postId) {
  return admin.firestore()
    .collection("users")
    .doc(uid)
    .collection(SAVED_POSTS)
    .doc(postId);
}

function savedPostDoc(postId, now) {
  return {
    postId,
    savedAt: admin.firestore.FieldValue.serverTimestamp(),
    savedAtMs: now,
  };
}

function reportRefFor(parts) {
  const reportId = parts
    .map((part) => encodeURIComponent(strOr(part).trim()))
    .join("__");
  return admin.firestore().collection("reports").doc(reportId);
}

function upsertReport(tx, reportRef, createData, reason, now) {
  return tx.get(reportRef).then((reportSnap) => {
    if (reportSnap.exists) {
      tx.update(reportRef, {
        lastReason: reason,
        reportCount: admin.firestore.FieldValue.increment(1),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAtMs: now,
      });
      return;
    }
    tx.set(reportRef, {
      ...createData,
      reportId: reportRef.id,
      reason,
      lastReason: reason,
      reportCount: 1,
      status: "open",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAtMs: now,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: now,
    });
  });
}

async function commenterProfileFor(uid) {
  const db = admin.firestore();
  const publicSnap = await db.collection("public_users").doc(uid).get();
  const publicData = publicSnap.exists ? publicSnap.data() : {};
  if (publicData) {
    const name = strOr(publicData.displayName).trim();
    if (name) {
      return {
        displayName: name,
        photoURL: strOr(publicData.photoURL).trim(),
      };
    }
  }

  const userSnap = await db.collection("users").doc(uid).get();
  const userData = userSnap.exists ? userSnap.data() : {};
  return {
    displayName: strOr(userData && userData.displayName, "Friend").trim() ||
      "Friend",
    photoURL: strOr(userData && userData.photoURL).trim(),
  };
}

async function profileFor(uid) {
  return commenterProfileFor(uid);
}

async function deleteCollectionDocs(collectionRef, batchSize = 250) {
  let deleted = 0;
  while (true) {
    const snap = await collectionRef.limit(batchSize).get();
    if (snap.empty) return deleted;
    const batch = admin.firestore().batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    deleted += snap.size;
  }
}

async function deleteSavedPostRefs(postId, batchSize = 250) {
  let deleted = 0;
  while (true) {
    const snap = await admin.firestore()
      .collectionGroup(SAVED_POSTS)
      .where("postId", "==", postId)
      .limit(batchSize)
      .get();
    if (snap.empty) return deleted;
    const batch = admin.firestore().batch();
    snap.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    deleted += snap.size;
  }
}

function notificationRefFor(ownerId) {
  return admin.firestore()
    .collection("users")
    .doc(ownerId)
    .collection(NOTIFICATIONS)
    .doc();
}

function notificationDocRefFor(ownerId, notificationId) {
  return admin.firestore()
    .collection("users")
    .doc(ownerId)
    .collection(NOTIFICATIONS)
    .doc(notificationId);
}

function notificationReadPatch(now) {
  return {
    read: true,
    readAt: admin.firestore.FieldValue.serverTimestamp(),
    readAtMs: now,
  };
}

function socialNotificationDoc({
  notificationRef,
  type,
  actorId,
  actor,
  postId,
  post,
  text = "",
  now,
}) {
  return {
    notificationId: notificationRef.id,
    type,
    actorId,
    actorName: strOr(actor && actor.displayName, "Friend").trim() || "Friend",
    actorPhotoURL: strOr(actor && actor.photoURL).trim(),
    postId,
    postImageURL: strOr(post && post.imageURL).trim(),
    text: strOr(text).trim().slice(0, 160),
    read: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAtMs: now,
  };
}

async function assertPostExists(tx, postRef) {
  const postSnap = await tx.get(postRef);
  if (!postSnap.exists) {
    throw new functions.https.HttpsError("not-found", "post_not_found");
  }
  return postSnap;
}

const createSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "createSocialPost_v1");
    const uid = requireUid(context);
    const draft = requireCreatePostDraft(data, uid);
    const postRef = postRefFor(draft.postId);
    const owner = await profileFor(uid);
    const now = Date.now();
    const post = buildSocialPostDoc({ draft, uid, owner, now });

    await admin.firestore().runTransaction(async (tx) => {
      const snap = await tx.get(postRef);
      if (snap.exists) {
        throw new functions.https.HttpsError(
          "already-exists",
          "post_already_exists"
        );
      }
      tx.set(postRef, {
        ...post,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    });

    logEvent("social.post_created", {
      postId: draft.postId,
      uid,
      isStory: draft.isStory,
    });
    return { ok: true, post };
  }
);

const likeSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "likeSocialPost_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const postRef = postRefFor(postId);
    const likeRef = postRef.collection(SOCIAL_LIKES).doc(uid);
    const actor = await profileFor(uid);
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const post = postSnap.data() || {};
      const likeSnap = await tx.get(likeRef);
      if (likeSnap.exists) return;
      tx.set(likeRef, {
        uid,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
      tx.update(postRef, {
        likeCount: admin.firestore.FieldValue.increment(1),
      });
      const ownerId = strOr(post.ownerId).trim();
      if (ownerId && ownerId !== uid) {
        const notificationRef = notificationRefFor(ownerId);
        tx.set(notificationRef, socialNotificationDoc({
          notificationRef,
          type: "post_like",
          actorId: uid,
          actor,
          postId,
          post,
          now,
        }));
      }
    });

    logEvent("social.post_liked", { postId, uid });
    return { ok: true, liked: true };
  }
);

const saveSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "saveSocialPost_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const postRef = postRefFor(postId);
    const savedRef = savedPostRefFor(uid, postId);
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const post = postSnap.data() || {};
      if (post.isStory === true) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "story_save_denied"
        );
      }
      tx.set(savedRef, savedPostDoc(postId, now), { merge: true });
    });

    logEvent("social.post_saved", { postId, uid });
    return { ok: true, saved: true };
  }
);

const unsaveSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "unsaveSocialPost_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    await savedPostRefFor(uid, postId).delete();

    logEvent("social.post_unsaved", { postId, uid });
    return { ok: true, saved: false };
  }
);

const markNotificationRead_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "markNotificationRead_v1");
    const uid = requireUid(context);
    const notificationId = requireNotificationId(data);
    const notificationRef = notificationDocRefFor(uid, notificationId);
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const snap = await tx.get(notificationRef);
      if (!snap.exists) return;
      const current = snap.data() || {};
      if (current.read === true) return;
      tx.update(notificationRef, notificationReadPatch(now));
    });

    logEvent("social.notification_read", { notificationId, uid });
    return { ok: true };
  }
);

const deleteNotification_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "deleteNotification_v1");
    const uid = requireUid(context);
    const notificationId = requireNotificationId(data);
    await notificationDocRefFor(uid, notificationId).delete();

    logEvent("social.notification_deleted", { notificationId, uid });
    return { ok: true };
  }
);

const markAllNotificationsRead_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "markAllNotificationsRead_v1");
    const uid = requireUid(context);
    const rawLimit = Number(data && data.limit);
    const limit = Number.isFinite(rawLimit) ?
      Math.max(1, Math.min(MAX_MARK_NOTIFICATIONS_READ, Math.floor(rawLimit))) :
      MAX_MARK_NOTIFICATIONS_READ;
    const now = Date.now();
    const unread = await admin.firestore()
      .collection("users")
      .doc(uid)
      .collection(NOTIFICATIONS)
      .where("read", "==", false)
      .limit(limit)
      .get();

    if (unread.empty) {
      return { ok: true, updated: 0 };
    }

    const batch = admin.firestore().batch();
    unread.docs.forEach((doc) => {
      batch.update(doc.ref, notificationReadPatch(now));
    });
    await batch.commit();

    logEvent("social.notifications_marked_read", {
      uid,
      updated: unread.size,
    });
    return { ok: true, updated: unread.size };
  }
);

const unlikeSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "unlikeSocialPost_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const postRef = postRefFor(postId);
    const likeRef = postRef.collection(SOCIAL_LIKES).doc(uid);

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const likeSnap = await tx.get(likeRef);
      if (!likeSnap.exists) return;
      const currentCount = Number(postSnap.get("likeCount")) || 0;
      tx.delete(likeRef);
      tx.update(postRef, {
        likeCount: currentCount > 0 ?
          admin.firestore.FieldValue.increment(-1) :
          0,
      });
    });

    logEvent("social.post_unliked", { postId, uid });
    return { ok: true, liked: false };
  }
);

const shareSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "shareSocialPost_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const postRef = postRefFor(postId);
    const shareRef = postRef.collection(SOCIAL_SHARES).doc();
    const actor = await profileFor(uid);
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const post = postSnap.data() || {};
      tx.set(shareRef, {
        shareId: shareRef.id,
        uid,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
      tx.update(postRef, {
        shareCount: admin.firestore.FieldValue.increment(1),
      });
      const ownerId = strOr(post.ownerId).trim();
      if (ownerId && ownerId !== uid) {
        const notificationRef = notificationRefFor(ownerId);
        tx.set(notificationRef, socialNotificationDoc({
          notificationRef,
          type: "post_share",
          actorId: uid,
          actor,
          postId,
          post,
          now,
        }));
      }
    });

    logEvent("social.post_shared", { postId, uid });
    return { ok: true };
  }
);

const addSocialPostComment_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "addSocialPostComment_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const text = requireCommentText(data);
    const postRef = postRefFor(postId);
    const commentRef = postRef.collection(SOCIAL_COMMENTS).doc();
    const commenter = await commenterProfileFor(uid);
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const post = postSnap.data() || {};
      tx.set(commentRef, {
        commentId: commentRef.id,
        uid,
        displayName: commenter.displayName,
        photoURL: commenter.photoURL,
        text,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAtMs: now,
      });
      tx.update(postRef, {
        commentCount: admin.firestore.FieldValue.increment(1),
      });
      const ownerId = strOr(post.ownerId).trim();
      if (ownerId && ownerId !== uid) {
        const notificationRef = notificationRefFor(ownerId);
        tx.set(notificationRef, socialNotificationDoc({
          notificationRef,
          type: "post_comment",
          actorId: uid,
          actor: commenter,
          postId,
          post,
          text,
          now,
        }));
      }
    });

    logEvent("social.post_commented", { postId, uid });
    return {
      ok: true,
      comment: {
        commentId: commentRef.id,
        uid,
        displayName: commenter.displayName,
        photoURL: commenter.photoURL,
        text,
        createdAtMs: now,
      },
    };
  }
);

const deleteSocialPostComment_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "deleteSocialPostComment_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const commentId = requireCommentId(data);
    const postRef = postRefFor(postId);
    const commentRef = postRef.collection(SOCIAL_COMMENTS).doc(commentId);

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const commentSnap = await tx.get(commentRef);
      if (!commentSnap.exists) {
        throw new functions.https.HttpsError("not-found", "comment_not_found");
      }

      const post = postSnap.data() || {};
      const comment = commentSnap.data() || {};
      const ownerId = strOr(post.ownerId).trim();
      const commentUid = strOr(comment.uid).trim();
      if (uid !== ownerId && uid !== commentUid) {
        throw new functions.https.HttpsError(
          "permission-denied",
          "comment_delete_denied"
        );
      }

      const currentCount = Number(post.commentCount || 0);
      tx.delete(commentRef);
      tx.update(postRef, {
        commentCount: Math.max(0, currentCount - 1),
      });
    });

    const reportsReviewed = await reviewReportsForDeletedComment({
      postId,
      commentId,
      resolution: "comment_deleted_by_user",
      reviewedBy: uid,
      note: "Comment deleted by user.",
    });

    logEvent("social.comment_deleted", {
      postId,
      commentId,
      uid,
      reportsReviewed,
    });
    return { ok: true, reportsReviewed };
  }
);

const deleteSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "deleteSocialPost_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const postRef = postRefFor(postId);

    const postSnap = await postRef.get();
    if (!postSnap.exists) {
      return { ok: true, alreadyDeleted: true };
    }

    const post = postSnap.data() || {};
    const ownerId = strOr(post.ownerId).trim();
    if (ownerId !== uid) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "post_delete_denied"
      );
    }

    const childDeletes = {};
    for (const childName of SOCIAL_SUBCOLLECTIONS) {
      childDeletes[childName] = await deleteCollectionDocs(
        postRef.collection(childName)
      );
    }
    const savedRefsDeleted = await deleteSavedPostRefs(postId);
    const notificationsDeleted = await deleteCollectionGroupDocsByField({
      collectionId: "notifications",
      field: "postId",
      value: postId,
    });
    const reportsReviewed = await reviewReportsForDeletedPost({
      postId,
      resolution: "post_deleted_by_owner",
      reviewedBy: uid,
      note: "Post deleted by owner.",
    });
    const imagePath = strOr(post.imagePath).trim();

    await postRef.delete();
    const storageDelete = await deleteStoragePathIfSafe(imagePath, {
      allowedPrefixes: [`social_uploads/${ownerId}/`],
    });

    logEvent("social.post_deleted", {
      postId,
      uid,
      childDeletes,
      savedRefsDeleted,
      notificationsDeleted,
      reportsReviewed,
      storageDeleteAttempted: storageDelete.attempted === true,
      storageDeleted: storageDelete.deleted === true,
    });
    return {
      ok: true,
      childDeletes,
      savedRefsDeleted,
      notificationsDeleted,
      reportsReviewed,
      storageDelete,
    };
  }
);

const reportSocialPost_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "reportSocialPost_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const reason = requireReportReason(data);
    const postRef = postRefFor(postId);
    const reportRef = reportRefFor(["social_post", postId, uid]);
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const post = postSnap.data() || {};
      const ownerId = strOr(post.ownerId).trim();
      if (!ownerId || ownerId === uid) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "invalid_report_target"
        );
      }
      await upsertReport(
        tx,
        reportRef,
        {
          type: "social_post",
          reporterId: uid,
          reportedUserId: ownerId,
          postId,
        },
        reason,
        now
      );
    });

    logEvent("social.post_reported", { postId, uid });
    return { ok: true, reportId: reportRef.id };
  }
);

const reportSocialPostComment_v1 = functions.region(REGION).https.onCall(
  async (data, context) => {
    assertCallableAppCheck(context, "reportSocialPostComment_v1");
    const uid = requireUid(context);
    const postId = requirePostId(data);
    const commentId = requireCommentId(data);
    const reason = requireReportReason(data);
    const postRef = postRefFor(postId);
    const commentRef = postRef.collection(SOCIAL_COMMENTS).doc(commentId);
    const reportRef = reportRefFor(["social_comment", postId, commentId, uid]);
    const now = Date.now();

    await admin.firestore().runTransaction(async (tx) => {
      const postSnap = await assertPostExists(tx, postRef);
      const commentSnap = await tx.get(commentRef);
      if (!commentSnap.exists) {
        throw new functions.https.HttpsError("not-found", "comment_not_found");
      }

      const post = postSnap.data() || {};
      const comment = commentSnap.data() || {};
      const commentUid = strOr(comment.uid).trim();
      if (!commentUid || commentUid === uid) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "invalid_report_target"
        );
      }

      await upsertReport(
        tx,
        reportRef,
        {
          type: "social_comment",
          reporterId: uid,
          reportedUserId: commentUid,
          postOwnerId: strOr(post.ownerId).trim(),
          postId,
          commentId,
          commentText: strOr(comment.text).trim(),
        },
        reason,
        now
      );
    });

    logEvent("social.comment_reported", { postId, commentId, uid });
    return { ok: true, reportId: reportRef.id };
  }
);

module.exports = {
  createSocialPost_v1,
  likeSocialPost_v1,
  saveSocialPost_v1,
  unsaveSocialPost_v1,
  markNotificationRead_v1,
  deleteNotification_v1,
  markAllNotificationsRead_v1,
  unlikeSocialPost_v1,
  shareSocialPost_v1,
  addSocialPostComment_v1,
  deleteSocialPost_v1,
  deleteSocialPostComment_v1,
  reportSocialPost_v1,
  reportSocialPostComment_v1,
  _buildSocialPostDoc: buildSocialPostDoc,
  _requireCreatePostDraft: requireCreatePostDraft,
  _notificationReadPatch: notificationReadPatch,
  _savedPostDoc: savedPostDoc,
};
