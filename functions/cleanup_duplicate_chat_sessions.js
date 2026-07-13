const message = `
cleanup_duplicate_chat_sessions.js is deprecated and intentionally disabled.

Why it is unsafe:
- it was written against role-oriented speaker/listener assumptions
- Friendify now uses a sorted-pair chat-session contract
- running the old cleanup can recreate or preserve the wrong doc orientation

Use these scripts instead:
1. node backfill_chat_session_contract.js --dry-run
2. node migrate_chat_session_doc_ids.js --dry-run

If duplicate cleanup is still required after those migrations, write a new tool
that operates only on the sorted-pair contract:
- pairUserA / pairUserB
- participantIds
- pairKey
- actualListenerId
`;

console.error(message.trim());
process.exit(1);
