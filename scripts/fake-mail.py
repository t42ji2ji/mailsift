#!/usr/bin/env python3
"""Builds a fake home with an Apple Mail store of made-up mail, for load-testing MailSift without real mail.

    scripts/fake-mail.py <home> [--messages 50000] [--unread 10000]
    scripts/fake-mail.py <home> --add 5      # new unread mail into an existing store, as if it just arrived
    CFFIXED_USER_HOME=<home> build/MailSift.app/Contents/MacOS/MailSift

The app then reads <home>/Library/Mail and keeps its index under <home>/Library/Application Support/MailSift.
Models are symlinked to the real ones so nothing is downloaded. Mail actions still go to the real Mail.app, so
don't open messages (opening an unread one marks it read) or act on them while testing.
"""
import argparse
import os
import random
import sqlite3
import time
import uuid
from email.utils import formatdate

ACCOUNT = "F4CE0000-0000-4000-8000-000000000001"
EMAIL = "tester@example.com"
BOXES = ["INBOX", "Archive", "Sent"]

TOPICS = {
    "bill": (["信用卡帳單", "本期電費通知", "電信月結單", "Your invoice", "Payment receipt"],
             ["您本期應繳金額為 NT${n}，繳款截止日為下月 15 日。", "Your payment of ${n}.00 was received. Thank you.",
              "若已繳款請忽略此通知。帳單明細請登入網路銀行查詢。", "Invoice #{n} is attached. Amount due within 30 days."]),
    "shop": (["訂單已出貨", "您的包裹已送達", "Order confirmation", "Your order has shipped", "退貨申請已受理"],
             ["訂單編號 {n} 已交由物流配送，預計兩天內送達。", "Track your package with number {n}.",
              "商品：無線耳機 x1、手機殼 x2。付款方式：信用卡。", "Thanks for shopping with us. Estimated delivery in 3 days."]),
    "travel": (["航班行程確認", "訂房成功通知", "Your trip to Tokyo", "Boarding pass", "高鐵訂位代號"],
               ["您的航班 BR{n} 將於上午 8:30 起飛，請提前兩小時抵達機場。", "Check-in opens 24 hours before departure.",
                "入住日期 10/20，退房日期 10/23，含早餐。", "Your booking reference is {n}. Have a great trip."]),
    "work": (["週會議程", "Q3 report review", "專案進度更新", "Design review notes", "請協助確認合約"],
             ["附件是這週的進度，麻煩大家會前先看過。", "Can we move the sync to Thursday at 3pm?",
              "上線時程延到下週二，測試環境已經準備好。", "I left comments on the doc, mostly about the API shape."]),
    "news": (["本週精選文章", "Weekly digest", "限時優惠只到今晚", "New features this month", "會員專屬折扣"],
             ["點此查看本週最受歡迎的十篇文章。", "Here is what happened this week in tech.",
              "全館滿千折百，結帳輸入折扣碼即可使用。", "Unsubscribe at any time from your account settings."]),
    "friend": (["週末要不要去爬山", "生日快樂！", "Dinner on Friday?", "照片傳給你了", "好久不見"],
               ["上次說的那家店我訂好位子了，七點見。", "Long time no see! Are you around next week?",
                "照片在雲端相簿，連結在下面。", "最近好嗎？有空一起吃個飯吧。"]),
}
FILLER = ["這封信由系統自動發送，請勿直接回覆。", "If you have any questions, contact our support team.",
          "感謝您的支持與愛護。", "Best regards,", "祝 順心", "Please keep this email for your records.",
          "詳細資訊請參考官方網站。", "This message was sent to {email}."]
NAMES = ["王小明", "陳怡君", "林志豪", "Alice Chen", "Bob Lee", "Carol Wu", "David Lin", "張雅婷", "黃建宏", "Emily Huang"]


def message_dir(store, rowid):
    levels = "" if rowid < 1000 else "".join(d + "/" for d in reversed(str(rowid // 1000)))
    return f"{store}/Data/{levels}Messages"


def senders_list():
    rng = random.Random(7)
    out = []
    for topic in TOPICS:
        for k in range(30):
            name = rng.choice(NAMES) if topic in ("work", "friend") else f"{topic.title()} Service {k}"
            out.append((topic, f"{topic}{k}@{topic}-mail.example", name))
    return out


def write_message(rng, senders, stores, subjects, rowid, date, box, read):
    """Writes the .emlx and returns the messages row."""
    sender = rng.randrange(len(senders))
    topic, address, name = senders[sender]
    titles, lines = TOPICS[topic]
    n = rng.randrange(1000, 99999)
    subject = rng.choice(titles) + f" {n}"
    sid = subjects.setdefault(subject, len(subjects) + 1)
    body_lines = [rng.choice(lines).format(n=n) for _ in range(rng.randrange(3, 12))]
    body_lines += [rng.choice(FILLER).format(email=EMAIL) for _ in range(rng.randrange(2, 8))]
    body = "\n\n".join(body_lines)
    text = (f"From: {name} <{address}>\nTo: Tester <{EMAIL}>\nSubject: {subject}\nDate: {formatdate(date)}\n"
            f"Message-ID: <{rowid}@fake.example>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\n"
            f"Content-Transfer-Encoding: 8bit\n\n{body}\n")
    data = text.encode()
    d = message_dir(stores[box], rowid)
    os.makedirs(d, exist_ok=True)
    with open(f"{d}/{rowid}.emlx", "wb") as f:
        f.write(f"{len(data)}\n".encode() + data)
    flagged = 1 if rng.random() < 0.002 else 0
    return (rowid, box, date, None, sid, sender + 1, read, flagged, rowid, 0,
            rng.randrange(1, 9999) if topic == "news" else 0, 0)


def add(db, stores, count):
    rng = random.Random()
    senders = senders_list()
    first = db.execute("SELECT max(ROWID) FROM messages").fetchone()[0] + 1
    base = db.execute("SELECT max(ROWID) FROM subjects").fetchone()[0]
    subjects = {}
    rows = [write_message(rng, senders, stores, subjects, rowid, int(time.time()), 1, 0)
            for rowid in range(first, first + count)]
    db.executemany("INSERT INTO subjects VALUES(?, ?)", [(base + i, s) for s, i in subjects.items()])
    db.executemany("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                   [r[:4] + (base + r[4],) + r[5:] for r in rows])
    db.executemany("INSERT INTO recipients VALUES(?, ?)", [(r[0], len(senders) + 1) for r in rows])
    db.commit()
    print(f"added {count} unread messages from ROWID {first}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("home")
    ap.add_argument("--messages", type=int, default=50_000)
    ap.add_argument("--unread", type=int, default=10_000)
    ap.add_argument("--add", type=int, default=0)
    args = ap.parse_args()
    rng = random.Random(42)

    home = os.path.abspath(args.home)
    v10 = f"{home}/Library/Mail/V10"
    os.makedirs(f"{v10}/MailData", exist_ok=True)
    support = f"{home}/Library/Application Support/MailSift"
    os.makedirs(support, exist_ok=True)
    real_models = os.path.expanduser("~/Library/Application Support/MailSift/Models")
    if not os.path.exists(f"{support}/Models"):
        os.symlink(real_models, f"{support}/Models")

    db_path = f"{v10}/MailData/Envelope Index"
    stores = {i: f"{v10}/{ACCOUNT}/{name}.mbox/{str(uuid.UUID(int=i)).upper()}" for i, name in enumerate(BOXES, 1)}
    if args.add:
        add(sqlite3.connect(db_path), stores, args.add)
        return
    if os.path.exists(db_path):
        os.remove(db_path)
    db = sqlite3.connect(db_path)
    db.executescript("""
        CREATE TABLE mailboxes(ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects(ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses(ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages(ROWID INTEGER PRIMARY KEY, mailbox INTEGER, date_received INTEGER, subject_prefix TEXT,
            subject INTEGER, sender INTEGER, read INTEGER, flagged INTEGER, global_message_id INTEGER, deleted INTEGER,
            list_id_hash INTEGER, conversation_id INTEGER);
        CREATE TABLE labels(message_id INTEGER, mailbox_id INTEGER);
        CREATE TABLE recipients(message INTEGER, address INTEGER);
    """)
    for i, name in enumerate(BOXES, 1):
        db.execute("INSERT INTO mailboxes VALUES(?, ?)", (i, f"imap://{ACCOUNT}/{name}"))

    senders = senders_list()
    db.executemany("INSERT INTO addresses VALUES(?, ?, ?)",
                   [(i + 1, a, n) for i, (_, a, n) in enumerate(senders)] + [(len(senders) + 1, EMAIL, "Tester")])
    me = len(senders) + 1

    now = int(time.time())
    subjects, rows, recips = {}, [], []
    unread_left = args.unread
    for rowid in range(1, args.messages + 1):
        # Newest first in ROWID order, roughly one message every ten minutes going back.
        date = now - (args.messages - rowid) * 600 - rng.randrange(600)
        box = 1 if rowid > args.messages * 0.6 or rng.random() < 0.3 else rng.choice([2, 2, 2, 3])
        read = 1
        if box == 1 and unread_left > 0 and rowid > args.messages - args.unread * 3:
            read, unread_left = 0, unread_left - 1
        rows.append(write_message(rng, senders, stores, subjects, rowid, date, box, read))
        recips.append((rowid, me))

    db.executemany("INSERT INTO subjects VALUES(?, ?)", [(i, s) for s, i in subjects.items()])
    db.executemany("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    db.executemany("INSERT INTO recipients VALUES(?, ?)", recips)
    db.commit()
    unread = sum(1 for r in rows if r[1] == 1 and r[6] == 0)
    print(f"{args.messages} messages, {unread} unread in INBOX, under {home}")


if __name__ == "__main__":
    main()
