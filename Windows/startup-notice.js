'use strict';

const NOTICE_TEXT = '本软件仅供学习交流使用，首先确保您有权下载用户视频，如无请于下载后24小时删除下载内容。下载者涉及版权侵权等问题和软件作者无关，请勿触犯法律法规，正确正当使用本软件！';

async function showStartupNotice(dialog) {
  const result = await dialog.showMessageBox({
    type: 'info', title: '软件使用声明', message: '软件使用声明',
    detail: NOTICE_TEXT,
    buttons: ['退出软件', '我已知晓'],
    defaultId: 0, cancelId: 0, noLink: true
  });
  // Only the explicit acknowledgement enters the application. Closing the
  // dialog, Escape or the default action exits; nothing is persisted.
  return result.response === 1;
}

module.exports = { NOTICE_TEXT, showStartupNotice };
