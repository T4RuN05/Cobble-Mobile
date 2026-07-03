# Bring Your Own Storage (BYOS) Architecture
**Target Concept:** Google Drive Multi-User Synchronization Strategy for Cobble

## 1. Architectural Overview
To bypass Supabase's 1 GB free-tier storage limit and support unlimited users for free, Cobble will adopt a hybrid "BYOS" architecture. 
- **Supabase** will act purely as the "brain" (Authentication and File Metadata).
- **Google Drive** will act as the "brawn" (Storing the large `.xopp` files).

Because Supabase only stores lightweight text data (metadata), the 500 MB database limit can easily accommodate hundreds of thousands of files across thousands of users.

## 2. Database Schema (Supabase)
The `cobble_metadata` table must be updated to securely track multi-user environments.

### New Schema
```sql
CREATE TABLE cobble_metadata (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.users(id) NOT NULL,
    filename TEXT NOT NULL,
    drive_file_id TEXT NOT NULL,         -- The unique ID from Google Drive
    last_updated TIMESTAMPTZ NOT NULL,
    tags TEXT[] DEFAULT '{}'
);
```

### Row Level Security (RLS)
To prevent users from seeing other people's files, enable RLS:
```sql
ALTER TABLE cobble_metadata ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can only see their own files" 
ON cobble_metadata FOR ALL 
USING (auth.uid() = user_id);
```

## 3. The Authentication Flow (OAuth)
We will use Supabase Auth configured with Google OAuth. 

**Crucial Scope:** During the OAuth flow, we must request the `https://www.googleapis.com/auth/drive.file` scope.
*This scope is restricted. It only allows Cobble to view and modify files that Cobble created itself. It completely protects the user's personal Drive files from our app, building user trust.*

When the user logs in, Supabase will provide a JWT for database access, AND a `provider_token` (the Google access token). This Google access token will be used to upload/download files.

## 4. Flutter Mobile Implementation
**Libraries needed:** `supabase_flutter`, `google_sign_in`, `http`.

### Login Flow
```dart
import 'package:google_sign_in/google_sign_in.dart';

final GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: ['https://www.googleapis.com/auth/drive.file'],
);

// 1. User signs in with Google Native UI
final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
final GoogleSignInAuthentication googleAuth = await googleUser!.authentication;

// 2. Pass tokens to Supabase to establish database session
final AuthResponse response = await supabase.auth.signInWithIdToken(
  provider: OAuthProvider.google,
  idToken: googleAuth.idToken!,
  accessToken: googleAuth.accessToken!,
);

// 3. Keep the googleAuth.accessToken safely stored to make REST calls to Google Drive
```

### Downloading a File
```dart
// Fetch the drive_file_id from Supabase
final metadata = await supabase.from('cobble_metadata').select();
final driveFileId = metadata[0]['drive_file_id'];

// Download directly from Google Drive (Supabase is bypassed)
final response = await http.get(
  Uri.parse('https://www.googleapis.com/drive/v3/files/$driveFileId?alt=media'),
  headers: { 'Authorization': 'Bearer $googleAccessToken' },
);
File(localPath).writeAsBytesSync(response.bodyBytes);
```

## 5. C++ Desktop Implementation (Xournal++)
Since C++ does not have a native Google Sign-in popup, we must use the **PKCE OAuth Flow**.

### Login Flow
1. C++ starts a temporary local server on `http://127.0.0.1:8080`.
2. C++ opens the system's default Web Browser to the Supabase Google Auth URL (with the Drive scope requested).
3. The user logs in via the browser.
4. Google redirects the browser to `http://127.0.0.1:8080/callback?provider_token=XYZ`.
5. The C++ server captures the token, saves it securely to the OS Keychain (or an encrypted file), and closes the server.

### Uploading a File (C++ httplib)
When saving a file, upload it directly to Google Drive using standard HTTP requests:

```cpp
httplib::Client cli("https://www.googleapis.com");
httplib::Headers headers = {
  {"Authorization", "Bearer " + google_access_token},
  {"Content-Type", "application/octet-stream"}
};

// POST to Google Drive Upload API
auto res = cli.Post("/upload/drive/v3/files?uploadType=media", headers, file_content, "application/octet-stream");

// Parse the JSON response to get the newly generated drive_file_id
// ...

// Insert metadata row into Supabase
httplib::Client supa_cli("https://XYZ.supabase.co");
supa_cli.Post("/rest/v1/cobble_metadata", supa_headers, "{\"filename\":\"math.xopp\", \"drive_file_id\":\"...\"}", "application/json");
```

## 6. Sync Conflict Strategy
Because files are stored on Google Drive and metadata on Supabase, the timestamp in Supabase is the "source of truth".
1. When offline, modifications are saved locally.
2. Upon reconnecting, compare local `lastModified` against Supabase `last_updated`.
3. If local is newer, `PATCH` the file to Google Drive and `UPDATE` the timestamp in Supabase.
4. If cloud is newer, download from Google Drive and overwrite local. 
