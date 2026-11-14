#!/usr/bin/env python3
"""
Access Requests Manager
Manages registration access requests for the network node Telegram bot.
Supports approval, rejection, persistent storage with atomic file locking,
and prevents unauthorized instant self-service access.
"""

import os
import json
import fcntl
import logging
from datetime import datetime, timezone
from typing import Optional, Dict, Any, Tuple

logger = logging.getLogger("requests_manager")

def get_default_requests_path() -> str:
    return os.getenv("ACCESS_REQUESTS_PATH", "/opt/incy-bot/access_requests.json")


def get_default_requests_lock() -> str:
    return os.getenv("ACCESS_REQUESTS_LOCK", "/tmp/access_requests.lock")


def _lock_and_load_requests(
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> Tuple[Dict[str, Any], int]:
    """
    Acquires an exclusive file lock and loads access requests registry JSON.
    Returns (data, lock_fd). Caller MUST close lock_fd (or call _save_and_unlock_requests).
    """
    reg_path = registry_path or get_default_requests_path()
    l_path = lock_path or get_default_requests_lock()

    lock_dir = os.path.dirname(l_path)
    if lock_dir:
        os.makedirs(lock_dir, exist_ok=True)

    lock_fd = os.open(l_path, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    requests_data: Dict[str, Any] = {}
    if os.path.exists(reg_path):
        try:
            with open(reg_path, "r", encoding="utf-8") as f:
                requests_data = json.load(f)
        except Exception as e:
            logger.warning("Could not read access requests from '%s', starting empty: %s", reg_path, e)
            requests_data = {}

    return requests_data, lock_fd


def _save_and_unlock_requests(
    requests_data: Dict[str, Any],
    lock_fd: int,
    registry_path: Optional[str] = None
) -> None:
    """
    Atomically writes access requests to disk and releases file lock.
    """
    reg_path = registry_path or get_default_requests_path()
    reg_dir = os.path.dirname(reg_path)
    if reg_dir:
        os.makedirs(reg_dir, exist_ok=True)

    tmp_path = f"{reg_path}.tmp.{os.getpid()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(requests_data, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())

        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, reg_path)
    finally:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


def get_access_request(
    tg_id: int,
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """
    Retrieves the access request for the given Telegram user ID.
    """
    requests_data, lock_fd = _lock_and_load_requests(registry_path, lock_path)
    try:
        return requests_data.get(str(tg_id))
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


def save_access_request(
    tg_id: int,
    user_info: Dict[str, Any],
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> Dict[str, Any]:
    """
    Creates or updates a pending access request for a Telegram user.
    """
    reg_path = registry_path or get_default_requests_path()
    requests_data, lock_fd = _lock_and_load_requests(reg_path, lock_path)
    try:
        key = str(tg_id)
        now_iso = datetime.now(timezone.utc).isoformat()
        existing = requests_data.get(key, {})

        req_entry = {
            "tg_id": tg_id,
            "tg_username": user_info.get("tg_username") or existing.get("tg_username") or "",
            "tg_first_name": user_info.get("tg_first_name") or existing.get("tg_first_name") or "",
            "tg_last_name": user_info.get("tg_last_name") or existing.get("tg_last_name") or "",
            "status": "pending",
            "requested_at": now_iso,
            "reviewed_by": None,
            "reviewed_at": None,
            "username": None
        }
        requests_data[key] = req_entry
        _save_and_unlock_requests(requests_data, lock_fd, reg_path)
        return req_entry
    except Exception:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)
        raise


def approve_access_request(
    tg_id: int,
    admin_id: int,
    assigned_username: str,
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """
    Marks an access request as approved and binds assigned username.
    """
    reg_path = registry_path or get_default_requests_path()
    requests_data, lock_fd = _lock_and_load_requests(reg_path, lock_path)
    try:
        key = str(tg_id)
        if key not in requests_data:
            return None
        now_iso = datetime.now(timezone.utc).isoformat()
        requests_data[key]["status"] = "approved"
        requests_data[key]["reviewed_by"] = admin_id
        requests_data[key]["reviewed_at"] = now_iso
        requests_data[key]["username"] = assigned_username
        res = dict(requests_data[key])
        _save_and_unlock_requests(requests_data, lock_fd, reg_path)
        return res
    except Exception:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)
        raise


def reject_access_request(
    tg_id: int,
    admin_id: int,
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> Optional[Dict[str, Any]]:
    """
    Marks an access request as rejected.
    """
    reg_path = registry_path or get_default_requests_path()
    requests_data, lock_fd = _lock_and_load_requests(reg_path, lock_path)
    try:
        key = str(tg_id)
        if key not in requests_data:
            return None
        now_iso = datetime.now(timezone.utc).isoformat()
        requests_data[key]["status"] = "rejected"
        requests_data[key]["reviewed_by"] = admin_id
        requests_data[key]["reviewed_at"] = now_iso
        res = dict(requests_data[key])
        _save_and_unlock_requests(requests_data, lock_fd, reg_path)
        return res
    except Exception:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)
        raise


def get_pending_requests(
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> Dict[str, Dict[str, Any]]:
    """
    Returns all requests currently with 'pending' status.
    """
    requests_data, lock_fd = _lock_and_load_requests(registry_path, lock_path)
    try:
        return {
            k: v for k, v in requests_data.items()
            if isinstance(v, dict) and v.get("status") == "pending"
        }
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)


def delete_access_request(
    tg_id: int,
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> bool:
    """
    Deletes an access request by Telegram user ID.
    """
    reg_path = registry_path or get_default_requests_path()
    requests_data, lock_fd = _lock_and_load_requests(reg_path, lock_path)
    try:
        key = str(tg_id)
        if key in requests_data:
            del requests_data[key]
            _save_and_unlock_requests(requests_data, lock_fd, reg_path)
            return True
        else:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(lock_fd)
            return False
    except Exception:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)
        raise


def delete_access_request_by_username(
    username: str,
    registry_path: Optional[str] = None,
    lock_path: Optional[str] = None
) -> bool:
    """
    Finds and deletes an access request associated with the given node username.
    """
    reg_path = registry_path or get_default_requests_path()
    requests_data, lock_fd = _lock_and_load_requests(reg_path, lock_path)
    try:
        found_key = None
        for k, v in requests_data.items():
            if isinstance(v, dict) and v.get("username") == username:
                found_key = k
                break
        if found_key:
            del requests_data[found_key]
            _save_and_unlock_requests(requests_data, lock_fd, reg_path)
            return True
        else:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(lock_fd)
            return False
    except Exception:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(lock_fd)
        raise
