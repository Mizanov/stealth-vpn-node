#!/usr/bin/env python3
"""
Unit and integration tests for the Request & Approval access workflow.
Tests:
1. send_user_cabinet for new, pending, and rejected users.
2. request_access_handler: request creation, anti-spam, admin notification.
3. callback_handler: appr_ and rejc_ actions, non-admin protection, credential delivery via ChatTarget.
4. list_requests_command: admin listing of pending requests.
5. ChatTarget adapter functionality.
"""

import os
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bot")))

# Mock qrcode and telegram modules if not present locally
if "qrcode" not in sys.modules:
    sys.modules["qrcode"] = MagicMock()
if "telegram" not in sys.modules:
    tg_mock = MagicMock()
    class MockInlineKeyboardButton:
        def __init__(self, text, url=None, callback_data=None):
            self.text = text
            self.url = url
            self.callback_data = callback_data
    tg_mock.InlineKeyboardButton = MockInlineKeyboardButton
    class MockInlineKeyboardMarkup:
        def __init__(self, inline_keyboard):
            self.inline_keyboard = inline_keyboard
    tg_mock.InlineKeyboardMarkup = MockInlineKeyboardMarkup
    tg_mock.ReplyKeyboardMarkup = MagicMock()
    sys.modules["telegram"] = tg_mock
if "telegram.ext" not in sys.modules:
    sys.modules["telegram.ext"] = MagicMock()

os.environ["TELEGRAM_BOT_TOKEN"] = "123456:mock_token_for_tests"
os.environ["TELEGRAM_ADMIN_IDS"] = "12345678,1001,1002"

import bot
import requests_manager


class TestAccessApprovalFlow(unittest.IsolatedAsyncioTestCase):

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.req_path = os.path.join(self.temp_dir.name, "access_requests.json")
        self.lock_path = os.path.join(self.temp_dir.name, "access_requests.lock")

        self.orig_req_env = os.environ.get("ACCESS_REQUESTS_PATH")
        self.orig_lock_env = os.environ.get("ACCESS_REQUESTS_LOCK")
        os.environ["ACCESS_REQUESTS_PATH"] = self.req_path
        os.environ["ACCESS_REQUESTS_LOCK"] = self.lock_path

    def tearDown(self):
        if self.orig_req_env is not None:
            os.environ["ACCESS_REQUESTS_PATH"] = self.orig_req_env
        else:
            os.environ.pop("ACCESS_REQUESTS_PATH", None)

        if self.orig_lock_env is not None:
            os.environ["ACCESS_REQUESTS_LOCK"] = self.orig_lock_env
        else:
            os.environ.pop("ACCESS_REQUESTS_LOCK", None)
        self.temp_dir.cleanup()

    async def test_chat_target_adapter(self):
        mock_bot = MagicMock()
        mock_bot.send_photo = AsyncMock()
        mock_bot.send_message = AsyncMock()

        target = bot.ChatTarget(mock_bot, 777)
        await target.reply_photo("photo_bytes", caption="Cap")
        mock_bot.send_photo.assert_awaited_once_with("photo_bytes", chat_id=777, caption="Cap")

        await target.reply_text("Hello", parse_mode="Markdown")
        mock_bot.send_message.assert_awaited_once_with("Hello", chat_id=777, parse_mode="Markdown")

    async def test_user_cabinet_unregistered_states(self):
        update = MagicMock()
        update.callback_query = None
        update.message = AsyncMock()
        update.effective_user.id = 5001
        update.effective_user.first_name = "Alex"
        context = MagicMock()

        with patch.object(bot, "get_user_by_tg_id", return_value=None):
            # 1. Brand new user - prompt to request access
            await bot.send_user_cabinet(update, context)
            sent_text = update.message.reply_text.call_args_list[0].args[0]
            self.assertIn("Запросить доступ", sent_text)

            # 2. Pending user
            requests_manager.save_access_request(5001, {"tg_username": "alex5001"})
            update.message.reply_text.reset_mock()
            await bot.send_user_cabinet(update, context)
            sent_text = update.message.reply_text.call_args_list[0].args[0]
            self.assertIn("находится на рассмотрении", sent_text)

            # 3. Rejected user
            requests_manager.reject_access_request(5001, 1001)
            update.message.reply_text.reset_mock()
            await bot.send_user_cabinet(update, context)
            sent_text = update.message.reply_text.call_args_list[0].args[0]
            self.assertIn("была отклонена", sent_text)

    async def test_request_access_handler_flow(self):
        update = MagicMock()
        update.callback_query = None
        update.message = AsyncMock()
        update.effective_user.id = 6001
        update.effective_user.username = "newbie"
        update.effective_user.first_name = "Newbie"
        update.effective_user.last_name = "User"
        update.effective_user.full_name = "Newbie User"
        context = MagicMock()
        context.bot.send_message = AsyncMock()

        with patch.object(bot, "get_user_by_tg_id", return_value=None):
            # First request -> saved and admins notified
            await bot.request_access_handler(update, context)

            req = requests_manager.get_access_request(6001)
            self.assertIsNotNone(req)
            self.assertEqual(req["status"], "pending")
            self.assertEqual(req["tg_username"], "newbie")

            # Confirmed to user
            update.message.reply_text.assert_awaited_once()
            user_text = update.message.reply_text.call_args.args[0]
            self.assertIn("Заявка на доступ успешно отправлена", user_text)

            # All admins notified
            self.assertEqual(context.bot.send_message.await_count, len(bot.ADMIN_IDS))
            admin_ids_notified = {call.kwargs["chat_id"] for call in context.bot.send_message.await_args_list}
            self.assertEqual(admin_ids_notified, set(bot.ADMIN_IDS))

            # Repeated request attempt -> blocked
            update.message.reply_text.reset_mock()
            await bot.request_access_handler(update, context)
            repeat_text = update.message.reply_text.call_args.args[0]
            self.assertIn("уже отправлена администратору", repeat_text)

    async def test_admin_approve_and_reject_callbacks(self):
        context = MagicMock()
        context.bot.send_message = AsyncMock()
        context.bot.send_photo = AsyncMock()

        # Save a pending request
        requests_manager.save_access_request(7001, {
            "tg_username": "target_user",
            "tg_first_name": "Target",
            "tg_last_name": "Name"
        })

        # 1. Non-admin trying to approve -> rejected
        non_admin_update = MagicMock()
        non_admin_update.callback_query = AsyncMock()
        non_admin_update.callback_query.data = "appr_7001"
        non_admin_update.effective_user.id = 9999
        await bot.callback_handler(non_admin_update, context)
        self.assertEqual(non_admin_update.callback_query.answer.await_count, 2)
        non_admin_update.callback_query.answer.assert_awaited_with(
            "⛔ Доступ запрещён. Требуются права администратора.", show_alert=True
        )

        # 2. Real admin approves
        admin_update = MagicMock()
        admin_update.callback_query = AsyncMock()
        admin_update.callback_query.data = "appr_7001"
        admin_update.callback_query.message = AsyncMock()
        admin_update.effective_user.id = 1001
        admin_update.effective_user.first_name = "AdminBob"

        mock_sub_res = {
            "token": "tok_abc123",
            "sub_url": "https://example.com/sub/tok_abc123.txt",
            "vless_reality_link": "vless://test",
            "hy2_link": "hy2://test",
            "vless_xhttp_link": "vless://xhttp"
        }

        with patch.object(bot, "get_user_by_tg_id", return_value=None), \
             patch.object(bot, "get_users_list", return_value=[]), \
             patch.object(bot, "create_user_singbox", return_value=mock_sub_res) as mock_create, \
             patch.object(bot, "deliver_user_credentials", new_callable=AsyncMock) as mock_deliver:

            await bot.callback_handler(admin_update, context)

            mock_create.assert_called_once()
            candidate_name = mock_create.call_args.args[0]
            self.assertEqual(candidate_name, "tg_target_user")

            # Request is marked approved
            req = requests_manager.get_access_request(7001)
            self.assertEqual(req["status"], "approved")
            self.assertEqual(req["username"], "tg_target_user")
            self.assertEqual(req["reviewed_by"], 1001)

            # Admin message updated
            admin_update.callback_query.edit_message_text.assert_awaited_once()
            edit_text = admin_update.callback_query.edit_message_text.call_args.kwargs["text"]
            self.assertIn("Заявка одобрена", edit_text)
            self.assertIn("tg_target_user", edit_text)

            # Credentials delivered to user target
            mock_deliver.assert_awaited_once()
            target_arg = mock_deliver.call_args.args[0]
            self.assertIsInstance(target_arg, bot.ChatTarget)
            self.assertEqual(target_arg.chat_id, 7001)

        # 3. Reject flow
        requests_manager.save_access_request(8001, {
            "tg_username": "spammer",
            "tg_first_name": "Spam"
        })

        rejc_update = MagicMock()
        rejc_update.callback_query = AsyncMock()
        rejc_update.callback_query.data = "rejc_8001"
        rejc_update.callback_query.message = AsyncMock()
        rejc_update.effective_user.id = 1001
        rejc_update.effective_user.first_name = "AdminBob"

        await bot.callback_handler(rejc_update, context)

        req_rejc = requests_manager.get_access_request(8001)
        self.assertEqual(req_rejc["status"], "rejected")
        self.assertEqual(req_rejc["reviewed_by"], 1001)

        rejc_update.callback_query.edit_message_text.assert_awaited_once()
        rejc_text = rejc_update.callback_query.edit_message_text.call_args.kwargs["text"]
        self.assertIn("Заявка отклонена", rejc_text)

        # User notified of rejection
        context.bot.send_message.assert_awaited_with(
            chat_id=8001,
            text="❌ К сожалению, ваша заявка на подключение к узлу была отклонена администратором."
        )

    async def test_list_requests_command(self):
        update = MagicMock()
        update.callback_query = None
        update.message = AsyncMock()
        update.effective_user.id = 1001
        context = MagicMock()

        # No requests
        await bot.list_requests_command(update, context)
        update.message.reply_text.assert_awaited_once()
        self.assertIn("Нет ожидающих заявок", update.message.reply_text.call_args.args[0])

        # Add 2 pending requests
        requests_manager.save_access_request(111, {"tg_username": "u1", "tg_first_name": "UserOne"})
        requests_manager.save_access_request(222, {"tg_username": "u2", "tg_first_name": "UserTwo"})

        update.message.reply_text.reset_mock()
        await bot.list_requests_command(update, context)
        # Header + 2 cards = 3 reply_text calls
        self.assertEqual(update.message.reply_text.await_count, 3)
        header_call = update.message.reply_text.call_args_list[0].args[0]
        self.assertIn("Ожидающие заявки на подключение (2)", header_call)


if __name__ == "__main__":
    unittest.main()
