#!/usr/bin/env python3
"""
Unit tests for requests_manager.py
Tests file-locked atomic storage, request creation, approval, rejection,
pending filtering, and deletion.
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bot")))

from requests_manager import (
    get_access_request,
    save_access_request,
    approve_access_request,
    reject_access_request,
    get_pending_requests,
    delete_access_request,
    delete_access_request_by_username
)


class TestRequestsManager(unittest.TestCase):

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.reg_path = os.path.join(self.temp_dir.name, "access_requests.json")
        self.lock_path = os.path.join(self.temp_dir.name, "access_requests.lock")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_save_and_get_request(self):
        user_info = {
            "tg_username": "ivan_test",
            "tg_first_name": "Ivan",
            "tg_last_name": "Petrov"
        }
        saved = save_access_request(111222, user_info, self.reg_path, self.lock_path)
        self.assertEqual(saved["status"], "pending")
        self.assertEqual(saved["tg_username"], "ivan_test")

        fetched = get_access_request(111222, self.reg_path, self.lock_path)
        self.assertIsNotNone(fetched)
        self.assertEqual(fetched["tg_first_name"], "Ivan")
        self.assertEqual(fetched["status"], "pending")

    def test_approve_request(self):
        user_info = {"tg_username": "anna_test", "tg_first_name": "Anna"}
        save_access_request(333444, user_info, self.reg_path, self.lock_path)

        approved = approve_access_request(
            tg_id=333444,
            admin_id=999,
            assigned_username="tg_anna_test",
            registry_path=self.reg_path,
            lock_path=self.lock_path
        )
        self.assertIsNotNone(approved)
        self.assertEqual(approved["status"], "approved")
        self.assertEqual(approved["username"], "tg_anna_test")
        self.assertEqual(approved["reviewed_by"], 999)

        # Pending list should now be empty
        pending = get_pending_requests(self.reg_path, self.lock_path)
        self.assertNotIn("333444", pending)

    def test_reject_request(self):
        user_info = {"tg_username": "intruder_user", "tg_first_name": "Bot"}
        save_access_request(555666, user_info, self.reg_path, self.lock_path)

        rejected = reject_access_request(
            tg_id=555666,
            admin_id=999,
            registry_path=self.reg_path,
            lock_path=self.lock_path
        )
        self.assertIsNotNone(rejected)
        self.assertEqual(rejected["status"], "rejected")
        self.assertEqual(rejected["reviewed_by"], 999)

        fetched = get_access_request(555666, self.reg_path, self.lock_path)
        self.assertEqual(fetched["status"], "rejected")

    def test_delete_request(self):
        user_info = {"tg_username": "del_user", "tg_first_name": "Del"}
        save_access_request(777888, user_info, self.reg_path, self.lock_path)
        self.assertTrue(delete_access_request(777888, self.reg_path, self.lock_path))
        self.assertIsNone(get_access_request(777888, self.reg_path, self.lock_path))

    def test_delete_request_by_username(self):
        user_info = {"tg_username": "bound_user", "tg_first_name": "Bound"}
        save_access_request(999000, user_info, self.reg_path, self.lock_path)
        approve_access_request(999000, 111, "tg_bound_user", self.reg_path, self.lock_path)

        self.assertTrue(delete_access_request_by_username("tg_bound_user", self.reg_path, self.lock_path))
        self.assertIsNone(get_access_request(999000, self.reg_path, self.lock_path))


if __name__ == "__main__":
    unittest.main()
