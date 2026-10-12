import Foundation

enum CloudSetupGuide {
    static let text = """
    GOOGLE DRIVE

    1. Откройте console.cloud.google.com под своим аккаунтом и создайте отдельный проект (например, Audiobook Studio Personal).
    2. В APIs & Services → Library включите Google Drive API.
    3. В Google Auth Platform настройте Branding: название, email поддержки и контактный email. В Audience выберите External; для личной проверки оставьте Testing и добавьте свой Google-аккаунт в Test users.
    4. В Data Access добавьте только https://www.googleapis.com/auth/drive.file. Полный доступ к Google Drive не нужен.
    5. В Clients создайте OAuth client типа Desktop app. Не выбирайте Web application. Скопируйте Client ID и Client Secret.
    6. В Audiobook Studio раскройте «Собственные проекты Google и Dropbox», заполните оба поля Google и нажмите «Использовать свой Google». Затем нажмите «Подключить» рядом с Google Drive, войдите в тот аккаунт, который добавлен в Test users, и разрешите доступ.

    Testing: подключение с доступом к Drive истекает через 7 дней; повторите вход. Для постоянного использования переведите проект в Production через Audience и выполните требования Google, показанные в консоли. Правила публикации зависят от аудитории и регистрации проекта.

    Новый OAuth-проект имеет отдельное разрешение drive.file: прежние книги могут не отображаться через него. Они остаются на вашем диске. Для доступа через бот вернитесь к прежнему проекту или загрузите готовые книги через новый.

    DROPBOX

    1. Откройте dropbox.com/developers/apps под своим аккаунтом → Create app.
    2. Выберите Scoped access и App folder; задайте уникальное название приложения.
    3. В Permissions включите files.metadata.read, files.content.write, sharing.read и sharing.write. Нажмите Submit.
    4. В Settings → OAuth 2 → Redirect URIs добавьте точно http://127.0.0.1:53682/oauth и сохраните.
    5. Скопируйте App key. App secret и Generate access token не нужны: Audiobook Studio использует PKCE и получает постоянное подключение после вашего согласия.
    6. В Audiobook Studio заполните Dropbox App key → «Использовать свой Dropbox». Затем нажмите «Подключить» рядом с Dropbox и разрешите доступ в браузере.

    Для своего аккаунта достаточно Development. Если подключаете другие аккаунты к своему приложению, включите Enable additional users; для широкого распространения выполните требования Dropbox Production.

    У каждого Dropbox-приложения своя папка Apps. Книги нового проекта сохраняются в Apps / название вашего приложения / Audiobook Studio / Автор - Название.

    СОХРАНЕНИЕ И ВОЗВРАТ

    Смена проекта не удаляет книги или токены прежнего подключения. «Встроенный проект» возвращает прежнюю регистрацию; если токен доступен, подключение восстановится. Собственный проект можно вернуть, указав прежний Client ID / App key. Google Client Secret достаточно ввести один раз: он хранится в Связке ключей.

    Перед сменой завершите или отмените все незавершённые книги в очереди. После переустановки системы восстановите проекты из резервной копии или введите свои идентификаторы заново и нажмите «Подключить». Не отправляйте свои токены другим людям.

    Официальные инструкции:
    https://developers.google.com/identity/protocols/oauth2/native-app
    https://developers.google.com/workspace/drive/api/guides/api-specific-auth
    https://developers.dropbox.com/oauth-guide
    https://www.dropbox.com/developers/reference/developer-guide
    """
}
