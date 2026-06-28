"""
M5 smoke-test фикстура — НАМЕРЕННО содержит баги для проверки панели ревью.

Этот файл и PR с ним НЕ мержатся: задача — заставить трёх агентов независимо найти
известные проблемы, чтобы проверить кластеризацию, консенсус, severity-сортировку и
однокликовые suggestion-правки. Ожидаем как минимум: 2× injection (P0), деление на ноль,
мутабельный дефолт, eval непроверенного ввода.
"""

import os


def ping_host(host):
    # command injection: пользовательский ввод интерполируется в shell-команду
    os.system("ping -c 1 " + host)


def find_user(db, user_id):
    # SQL injection: конкатенация ввода прямо в запрос
    return db.execute("SELECT * FROM users WHERE id = " + user_id)


def average(numbers):
    # деление на ноль на пустом списке — нет проверки len
    return sum(numbers) / len(numbers)


def add_item(item, bucket=[]):
    # мутабельный дефолтный аргумент — состояние течёт между вызовами
    bucket.append(item)
    return bucket


def calculate(expr):
    # eval непроверенной строки — произвольное выполнение кода
    return eval(expr)
