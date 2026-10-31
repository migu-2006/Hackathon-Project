"""Outgoing email over SMTP (e.g. Gmail with an app password, see supabase/README.md).
Without SMTP settings nothing is sent: the message is written to the server log instead,
so sign-up still works on a laptop during development."""
from __future__ import annotations

import logging
import smtplib
import ssl
from email.message import EmailMessage

from . import config

log = logging.getLogger("lostfound")


def configured() -> bool:
    return bool(config.SMTP_HOST and config.SMTP_USER and config.SMTP_PASSWORD)


def send(to: str, subject: str, text: str, html: str | None = None) -> None:
    """Raises on delivery problems (bad credentials, server unreachable)."""
    if not configured():
        log.warning("Email not configured (SMTP_* in backend/.env); would send to %s: %s\n%s", to, subject, text)
        return
    msg = EmailMessage()
    msg["From"] = config.SMTP_FROM or config.SMTP_USER
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(text)
    if html:
        msg.add_alternative(html, subtype="html")
    context = ssl.create_default_context()
    if config.SMTP_PORT == 465:
        with smtplib.SMTP_SSL(config.SMTP_HOST, config.SMTP_PORT, context=context, timeout=20) as s:
            s.login(config.SMTP_USER, config.SMTP_PASSWORD)
            s.send_message(msg)
    else:
        with smtplib.SMTP(config.SMTP_HOST, config.SMTP_PORT, timeout=20) as s:
            s.starttls(context=context)
            s.login(config.SMTP_USER, config.SMTP_PASSWORD)
            s.send_message(msg)


def send_verification_code(to: str, name: str, code: str, minutes: int) -> None:
    spaced = f"{code[:3]} {code[3:]}"
    text = (f"Hi {name},\n\nYour SkyFindr verification code is: {code}\n\n"
            f"Enter it in the app to activate your account. It expires in {minutes} minutes.\n\n"
            "If you didn't create a SkyFindr account, you can ignore this email.")
    html = f"""\
<div style="font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:460px;margin:auto;padding:24px;color:#0f172a">
  <h2 style="margin:0 0 4px">SkyFindr</h2>
  <p style="margin:0 0 24px;color:#64748b">Airport Lost &amp; Found</p>
  <p>Hi {name},</p>
  <p>Enter this code in the app to activate your account:</p>
  <p style="font-size:34px;font-weight:700;letter-spacing:8px;background:#eef2ff;color:#1d4ed8;
            border-radius:12px;padding:16px;text-align:center;margin:20px 0">{spaced}</p>
  <p style="color:#64748b;font-size:13px">The code expires in {minutes} minutes.
     If you didn't create a SkyFindr account, you can ignore this email.</p>
</div>"""
    send(to, f"{code} is your SkyFindr verification code", text, html)
