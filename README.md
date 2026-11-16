Репозиторий — место, где ты с телефона хранишь свои VLESS-ключи. Роутер с сервисом `vlesspool`
сам забирает [`keys.txt`](keys.txt), проверяет каждый ключ у себя (через sing-box, из твоей сети) и отдаёт
NetShift только рабочие.

## Как добавить ключи с телефона

1. Открой `keys.txt` в приложении GitHub или в браузере → карандаш.
2. Вставь ключи `vless://...`, base64-подписку или ссылку на подписку провайдера (`https://...`), по одной на строку.
   Строки с `#` игнорируются.
3. Commit. На роутере ключи подхватятся при ближайшей проверке (или нажми «Проверить сейчас» в LuCI).

Ссылка, которую берёт роутер:

```
https://raw.githubusercontent.com/ST3P4P/Vless_Pool/main/keys.txt
```

## Автопроверка на GitHub (необязательно)

`check.sh` и workflow `check-keys` собирают публичные списки ([igareck](https://github.com/igareck/vpn-configs-for-russia),
[vless-checker](https://tiagorrg.github.io/vless-checker/)) и кладут живые ключи в `data/good.txt`.
Расписание отключено, запускается вручную: Actions → check-keys → Run workflow. Проверка идёт из
дата-центра GitHub и не гарантирует, что ключ работает из твоей сети.
