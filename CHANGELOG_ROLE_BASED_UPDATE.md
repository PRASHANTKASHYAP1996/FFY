Friendify role-based chat/call update

Implemented
- Removed the listener-mode section from the Home screen flow.
- Made incoming chat/call request handling visible for every user, not only "listeners".
- Switched chat session identity to a single canonical pair per two users, so one shared chat history is reused regardless of who initiated first.
- Kept chat free after first acceptance.
- Kept calls request-based and paid.
- Added profile fields for gender, city, state, and country.
- Added discover filters for gender, nearby, statewise, favourites, topic, and language.
- Locked discover-screen call buttons so users are pushed into chat-first flow.
- Updated chat screen top action card to support:
  - pending chat acceptance
  - request call
  - approve call
  - deny call
  - call now after approval
- Updated backend call permission logic so the user who requested the call becomes the speaker and the accepter becomes the earning listener.
- Cleared one-time call approval after a real call starts, so each real call requires a fresh approval.
- Added public_users read rules and expanded user profile rules for the new gender/location fields.
- Expanded public user projection sync to include gender/location and activeCallId.

Notes
- Nearby filtering currently uses same city, falling back to same state, based on saved profile fields. It does not use device GPS.
- Existing users should be backfilled into public_users again after deploy so new public fields are available everywhere.
