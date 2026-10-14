"""客户端静默上报的错误（真实数据在数据目录旁的 diagnostics.jsonl，本模型只是后台页面入口）。"""
from django.db import models


class ClientDiagnostic(models.Model):
    """占位镜像：不映射任何 SQLite 表；列表页读取 diagnostics.jsonl（只读）。

    与 Quest 相同的模式：'client_diagnostics_stub' 表不存在，因此必须覆写
    get_object 直接拒绝，避免默认视图查不存在的表抛 500。
    """

    class Meta:
        managed = False
        db_table = 'client_diagnostics_stub'
        verbose_name = '客户端报错'
        verbose_name_plural = '客户端报错'
