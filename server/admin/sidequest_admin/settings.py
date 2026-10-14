"""支线服务端管理后台（本地运维工具，Django Admin）。

- 直挂现有 SQLite 数据文件（models 均为 managed=False，绝不改 schema/绝不建表）。
- 后台自身的数据（账号、会话、权限、操作日志）放在独立的 admin.sqlite，
  与业务数据库物理隔离，避免污染业务库。
- 仅监听 127.0.0.1，仅供本机运维使用；不要对公网开放。
"""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent   # server/admin
REPO_DIR = BASE_DIR.parent.parent                   # 项目根目录

# 本地调试工具：密钥仅用于本机；云端部署请用 SIDEQUEST_ADMIN_SECRET_KEY 覆盖
SECRET_KEY = os.environ.get(
    'SIDEQUEST_ADMIN_SECRET_KEY',
    'sidequest-admin-local-dev-only-2b9f4c6e8a1d3f5b7c9e1a3d5f7b9c2e',
)
DEBUG = True
ALLOWED_HOSTS = ['127.0.0.1', 'localhost']
# 云端部署时用环境变量追加（逗号分隔），例如 SIDEQUEST_ADMIN_HOSTS=gl.example.com
ALLOWED_HOSTS += [
    item.strip()
    for item in os.environ.get('SIDEQUEST_ADMIN_HOSTS', '').split(',')
    if item.strip()
]
CSRF_TRUSTED_ORIGINS = [
    item.strip()
    for item in os.environ.get('SIDEQUEST_ADMIN_ORIGINS', '').split(',')
    if item.strip()
]
# nginx 反代后 Django 能识别 https（配合 proxy_set_header X-Forwarded-Proto）
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

SIDEQUEST_DB = os.environ.get(
    'SIDEQUEST_DB', str(REPO_DIR / '.runtime' / 'realtest' / 'sidequest-v2.sqlite')
)
SIDEQUEST_MEDIA_DIR = Path(
    os.environ.get('SIDEQUEST_MEDIA_DIR', str(REPO_DIR / '.runtime' / 'realtest' / 'media'))
)

# 客户端静默上报的日志（由主服务 /api/diagnostics 写入，见 server/server.mjs）
SIDEQUEST_DIAGNOSTICS = Path(
    os.environ.get(
        'SIDEQUEST_DIAGNOSTICS',
        str(Path(SIDEQUEST_DB).parent / 'diagnostics.jsonl'),
    )
)

# 下载统计日志（由主服务在 /download 与 /download/latest 写入，见 server/server.mjs）
SIDEQUEST_DOWNLOADS = Path(
    os.environ.get(
        'SIDEQUEST_DOWNLOADS',
        str(Path(SIDEQUEST_DB).parent / 'downloads.jsonl'),
    )
)

# 版本分发：APK 上传目录与对外下载地址（主服务 /download 从同一个目录取最新包）
SIDEQUEST_APK_DIR = Path(
    os.environ.get('SIDEQUEST_APK_DIR', str(Path(SIDEQUEST_DB).parent / 'apk'))
)
SIDEQUEST_PUBLIC_BASE_URL = os.environ.get('SIDEQUEST_PUBLIC_BASE_URL', '').rstrip('/')

INSTALLED_APPS = [
    'unfold',
    'unfold.contrib.filters',
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'panel',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'sidequest_admin.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / 'templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'sidequest_admin.wsgi.application'

DATABASES = {
    'default': {   # 业务库：只读为主，绝不执行 Django 迁移
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': SIDEQUEST_DB,
        'OPTIONS': {'timeout': 10},
    },
    'django': {    # 后台自身数据：独立文件
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': str(BASE_DIR / 'admin.sqlite'),
        'OPTIONS': {'timeout': 10},
    },
}
DATABASE_ROUTERS = ['panel.router.AdminDatabaseRouter']

AUTH_PASSWORD_VALIDATORS = []

LANGUAGE_CODE = 'zh-hans'
TIME_ZONE = 'Asia/Shanghai'
USE_I18N = True
USE_TZ = True

STATIC_URL = 'static/'
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# 会话在后台本地文件里；关闭时清空会话即可
SESSION_ENGINE = 'django.contrib.sessions.backends.db'
# 后台登录会话：闲置 14 天过期；持续使用自动续期（避免固定到期被强制登出）
SESSION_COOKIE_AGE = 60 * 60 * 24 * 14
SESSION_SAVE_EVERY_REQUEST = True

# ---------------------------------------------------------------------------
# django-unfold：现代主题 + 导航分组 + 仪表盘
# ---------------------------------------------------------------------------
UNFOLD = {
    'SITE_TITLE': '支线管理',
    'SITE_HEADER': '支线 · 管理后台',
    'SITE_SUBHEADER': '本地运维工具',
    'SITE_SYMBOL': 'eco',
    'SHOW_HISTORY': True,
    'SHOW_VIEW_ON_SITE': False,
    'DASHBOARD_CALLBACK': 'panel.dashboard.dashboard_callback',
    'COLORS': {
        # 与客户端一致的森林绿主色
        'primary': {
            '50': '238 243 236',
            '100': '223 236 212',
            '200': '196 218 182',
            '300': '164 195 148',
            '400': '122 160 110',
            '500': '86 128 79',
            '600': '56 97 63',
            '700': '35 77 60',
            '800': '28 62 49',
            '900': '22 48 39',
            '950': '12 28 23',
        },
    },
    'SIDEBAR': {
        'show_search': True,
        'show_all_applications': False,
        'navigation': [
            {
                'title': '数据概览',
                'collapsible': True,
                'items': [
                    {'title': '仪表盘', 'icon': 'dashboard', 'link': '/admin/'},
                ],
            },
            {
                'title': '内容',
                'collapsible': True,
                'items': [
                    {'title': '探索任务', 'icon': 'explore', 'link': '/admin/panel/quest/'},
                    {'title': '记录', 'icon': 'edit_note', 'link': '/admin/panel/entry/'},
                    {'title': '媒体', 'icon': 'perm_media', 'link': '/admin/panel/media/'},
                    {'title': '媒体绑定', 'icon': 'link', 'link': '/admin/panel/mediabinding/'},
                ],
            },
            {
                'title': '分发',
                'collapsible': True,
                'items': [
                    {'title': '版本分发', 'icon': 'system_update', 'link': '/admin/panel/apkrelease/'},
                    {'title': '下载统计', 'icon': 'monitoring', 'link': '/admin/panel/downloadevent/'},
                ],
            },
            {
                'title': '账号与同步',
                'collapsible': True,
                'items': [
                    {'title': '账号', 'icon': 'group', 'link': '/admin/panel/user/'},
                    {'title': '活动进度', 'icon': 'route', 'link': '/admin/panel/queststate/'},
                    {'title': '同步分支', 'icon': 'sync', 'link': '/admin/panel/syncbranch/'},
                    {'title': '同步回执', 'icon': 'receipt_long', 'link': '/admin/panel/mutationreceipt/'},
                    {'title': '指令回执', 'icon': 'receipt', 'link': '/admin/panel/commandreceipt/'},
                ],
            },
            {
                'title': '排查工具',
                'collapsible': True,
                'items': [
                    {'title': '删除墓碑', 'icon': 'delete_history', 'link': '/admin/panel/entrytombstone/'},
                    {'title': '媒体清理队列', 'icon': 'cleaning_services', 'link': '/admin/panel/mediacleanup/'},
                    {'title': '登录会话', 'icon': 'key', 'link': '/admin/panel/loginsession/'},
                    {'title': '服务端元数据', 'icon': 'database', 'link': '/admin/panel/servermetadata/'},
                    {'title': '客户端报错', 'icon': 'bug_report', 'link': '/admin/panel/clientdiagnostic/'},
                ],
            },
        ],
    },
}
