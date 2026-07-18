#!/usr/bin/env python3
"""
Upload a local MP4 to YouTube with privacy=private by default.

First run opens a browser for OAuth consent and stores a refreshable token.
"""

import argparse
import json
import mimetypes
import os
import re
import sys
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

SCOPES = ["https://www.googleapis.com/auth/youtube.upload"]
API_SERVICE_NAME = "youtube"
API_VERSION = "v3"


def default_token_path() -> Path:
    base = Path.home() / ".config" / "bbb_videos_download"
    base.mkdir(parents=True, exist_ok=True)
    return base / "youtube_token.json"


def infer_title(video_path: Path) -> str:
    stem = video_path.stem
    stem = stem.replace("_", " ")
    stem = re.sub(r"\s+", " ", stem).strip()
    return stem or "BBB recording"


def load_description(description: str, description_file: str) -> str:
    if description_file:
        return Path(description_file).read_text(encoding="utf-8")
    return description or ""


def get_credentials(client_secrets_path: Path, token_path: Path) -> Credentials:
    creds = None
    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)

    if creds and creds.valid:
        return creds

    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    else:
        flow = InstalledAppFlow.from_client_secrets_file(str(client_secrets_path), SCOPES)
        creds = flow.run_local_server(port=0)

    token_path.write_text(creds.to_json(), encoding="utf-8")
    return creds


def upload_video(
    youtube,
    video_path: Path,
    title: str,
    description: str,
    privacy_status: str,
    category_id: str,
    made_for_kids: bool,
) -> dict:
    mime, _ = mimetypes.guess_type(str(video_path))
    media = MediaFileUpload(str(video_path), mimetype=mime or "video/mp4", resumable=True)

    request = youtube.videos().insert(
        part="snippet,status",
        body={
            "snippet": {
                "title": title,
                "description": description,
                "categoryId": category_id,
            },
            "status": {
                "privacyStatus": privacy_status,
                "selfDeclaredMadeForKids": made_for_kids,
            },
        },
        media_body=media,
    )

    response = None
    while response is None:
        _, response = request.next_chunk()

    return response


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload a video to YouTube (private by default)."
    )
    parser.add_argument("video", help="Path to the local video file (mp4, mov, etc.)")
    parser.add_argument("--title", help="YouTube title (default: inferred from filename)")
    parser.add_argument("--description", help="Inline description text")
    parser.add_argument("--description-file", help="Path to UTF-8 text file for description")
    parser.add_argument(
        "--privacy",
        choices=["private", "unlisted", "public"],
        default="private",
        help="Video visibility (default: private)",
    )
    parser.add_argument(
        "--category-id",
        default="27",
        help="YouTube category id (default: 27 = Education)",
    )
    parser.add_argument(
        "--made-for-kids",
        action="store_true",
        help="Mark video as made for kids",
    )
    parser.add_argument(
        "--client-secrets",
        default="youtube_client_secret.json",
        help="Path to OAuth client secret JSON from Google Cloud",
    )
    parser.add_argument(
        "--token",
        default=str(default_token_path()),
        help="Path to OAuth token cache file",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print payload and exit without uploading",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    video_path = Path(args.video).expanduser().resolve()
    if not video_path.exists() or not video_path.is_file():
        print(f"Error: video file not found: {video_path}", file=sys.stderr)
        return 1

    client_secrets_path = Path(args.client_secrets).expanduser().resolve()
    if not client_secrets_path.exists():
        print(
            "Error: OAuth client secret not found. "
            f"Expected: {client_secrets_path}",
            file=sys.stderr,
        )
        return 1

    token_path = Path(args.token).expanduser().resolve()
    token_path.parent.mkdir(parents=True, exist_ok=True)

    title = (args.title or "").strip() or infer_title(video_path)
    description = load_description(args.description, args.description_file)

    payload = {
        "video": str(video_path),
        "title": title,
        "privacy": args.privacy,
        "category_id": args.category_id,
        "made_for_kids": args.made_for_kids,
        "client_secrets": str(client_secrets_path),
        "token": str(token_path),
    }

    if args.dry_run:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    try:
        creds = get_credentials(client_secrets_path, token_path)
        youtube = build(API_SERVICE_NAME, API_VERSION, credentials=creds)
        response = upload_video(
            youtube=youtube,
            video_path=video_path,
            title=title,
            description=description,
            privacy_status=args.privacy,
            category_id=args.category_id,
            made_for_kids=args.made_for_kids,
        )
    except HttpError as err:
        print(f"YouTube API error: {err}", file=sys.stderr)
        return 2
    except Exception as err:  # pragma: no cover - operational fallback
        print(f"Upload failed: {err}", file=sys.stderr)
        return 3

    video_id = response.get("id", "")
    print(f"Uploaded: {video_id}")
    if video_id:
        print(f"Studio: https://studio.youtube.com/video/{video_id}/edit")
        print(f"Watch : https://www.youtube.com/watch?v={video_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
