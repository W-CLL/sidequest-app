"""账号与登录令牌：users / sessions 表。"""
from django.db import models


class User(models.Model):
    id = models.TextField(primary_key=True)
    nickname = models.TextField()
    normalized_nickname = models.TextField(unique=True)
    password_salt = models.TextField()
    password_hash = models.TextField()
    role = models.TextField()
    preferences = models.TextField()

    class Meta:
        managed = False
        db_table = 'users'
        verbose_name = '账号'
        verbose_name_plural = '账号'

    def __str__(self):
        return self.nickname


class LoginSession(models.Model):
    """业务库登录令牌。只读展示；撤销登录请走服务端流程，后台不提供删除入口。"""

    token_hash = models.TextField(primary_key=True, verbose_name='令牌哈希')
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='login_sessions',
        db_constraint=False,
        verbose_name='账号',
    )
    expires_at = models.BigIntegerField(verbose_name='过期时间(epoch ms)')
    client = models.TextField(blank=True, default='', verbose_name='登录来源')

    class Meta:
        managed = False
        db_table = 'sessions'
        verbose_name = '登录会话'
        verbose_name_plural = '登录会话'

    def __str__(self):
        return f'{self.user.nickname} 的会话'
