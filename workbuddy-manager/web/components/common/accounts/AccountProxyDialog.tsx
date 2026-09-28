'use client';

import {useEffect, useState} from 'react';
import {notify} from '@/lib/toast';
import {useT} from '@/lib/i18n/provider';
import {accountApi, errText} from '@/lib/api';
import type {Account} from '@/lib/types';
import {Button} from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/radix/dialog';
import {Input} from '@/components/ui/input';

/**
 * 账号出站代理的编辑弹窗（对齐 sub2api 的「每号单独代理」）。
 *
 * 为什么要这个东西：多账号部署里，同一批账号走同一个出口 IP 很容易被上游
 * 风控关联；把每个号挂到不同代理上，才能让它们看起来是不同来源。全局代理
 * 粒度太粗——一个部署里所有账号共用一个出口，等于没隔离。
 *
 * 存法：写进**上游账号文件本身的顶层 `proxy` 键**（`workbuddy-xxx.json`），
 * 与 `device_token` 同级。这是上游 Go 侧 `auth.Auth.ProxyURL` 读取的唯一位置，
 * 所以必须写文件——面板自己存一份（像备注那样）而 Go 侧读不到，等于白存。
 *
 * 生效方式：上游的 transport 池在启动时按账号建好、运行期不可变，所以保存后
 * 后端会触发一次上游重载（`reload.request_restart()`）。界面提示语来自后端
 * 返回的 `message`，会说清是「已生效」还是「需手动重启」，不会让用户以为点了
 * 就立刻通了。
 *
 * 空串 = 清除代理（账号回直连，后端从文件里删掉该键）。
 */
export function AccountProxyDialog({
  account,
  open,
  onOpenChange,
  onSaved,
}: {
  /** null = 未选中任何账号（弹窗关闭态） */
  account: Account | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const t = useT();
  const [proxy, setProxy] = useState('');
  const [busy, setBusy] = useState(false);

  // 每次打开都以该账号当前的代理为初值：否则会拿着上一个账号的内容去编辑，
  // 一点保存就把代理写串——多账号场景下「串号」意味着流量走错出口，
  // 比备注写串严重得多。
  useEffect(() => {
    if (open) {
      setProxy(account?.proxy ?? '');
      setBusy(false);
    }
  }, [open, account?.file, account?.proxy]);

  async function save() {
    if (!account || busy) return;
    const value = proxy.trim();
    // 前端先做一次轻校验：与后端同一套规则（必须带 scheme + 有主机名）。
    // 提前拦掉明显写错的输入，省一次往返。后端仍会独立校验（不信任前端）。
    if (value && !/^(https?|socks5h?):\/\/[^\s/]+/i.test(value)) {
      notify.err(t('accounts.proxyInvalid'));
      return;
    }
    setBusy(true);
    try {
      const r = await accountApi.setProxy(account.file, value);
      // 标题按「设上了 / 清掉了」分两种，细节用后端 message（含是否已重载）。
      notify.ok(r.proxy ? t('accounts.proxySaved') : t('accounts.proxyCleared'), r.message);
      onOpenChange(false);
      onSaved();
    } catch (e) {
      notify.err(errText(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-[440px]" showCloseButton>
        <DialogHeader>
          <DialogTitle>{t('accounts.proxyTitle')}</DialogTitle>
          <DialogDescription>
            {t('accounts.proxyDesc', {name: account?.nickname || account?.uid || ''})}
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <Input
            value={proxy}
            onChange={(e) => setProxy(e.target.value)}
            placeholder={t('accounts.proxyPlaceholder')}
            spellCheck={false}
            autoComplete="off"
            autoFocus
            onKeyDown={(e) => {
              if (e.key === 'Enter') void save();
            }}
          />
          <p className="text-xs text-muted-foreground leading-relaxed">
            {t('accounts.proxyHint')}
          </p>
          <div className="flex justify-end gap-2">
            <Button variant="outline" className="rounded-full" onClick={() => onOpenChange(false)}>
              {t('common.cancel')}
            </Button>
            <Button className="rounded-full" onClick={save} disabled={busy}>
              {t('common.save')}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
