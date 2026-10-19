//
//  DKVideoFeedTable.h
//  DYKiller
//
//  「视频表被底栏压缩」这一类裁剪源头的对外接口：表查找（供页面修饰层排除这类结构）、
//  撑高原高（供调试探针判断表有没有被撑高），以及 HUD 钉位的命中统计。
//

#ifndef DKVideoFeedTable_h
#define DKVideoFeedTable_h

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 视频表的基类 `AWEFeedDataSafeTableView`；取不到返回 nil。
Class DKVideoFeedTableClass(void);

/// 该视图所在的视频表；不在表内返回 nil。
UIView *DKFeedTableForView(UIView *view);

/// 该表撑高前的高度；没被撑高过返回 nil。
NSNumber *DKVideoFeedTableOriginalHeight(UIView *table);

/// 在详情页的原生行高或分页计算之前准备子表尺寸；未入树时取已加载控制器的高度。
BOOL DKVideoFeedTablePrepareForController(UIViewController *controller, UITableView *table);

/// 详情页建行与分页前准备、三个行高入口的调用及修正统计。
NSString *DKVideoDetailTableStats(void);

/// 翻页偏移现场：当前 offsetY、视口高、内容高与页数、落在哪一行与该行行顶/行高。
/// 供探针确认「偏移不是任何一整页的倍数」这类现场，下次换机型不用重新推断。
///
/// 只诊断、不改偏移。偏移会越用越偏的根因在 DKVideoDetailTable.xm 的正反两个换算入口，
/// 在那里修；在布局回调里写 contentOffset 会自我触发，反而把错误放大。
NSString *DKVideoFeedTableOffsetStats(UITableView *table);

/// HUD 钉位与视频表修正的会话累计统计；首页和详情控制器布局分别报告调用与补正次数。
NSString *DKVideoFeedTableStats(void);

#ifdef __cplusplus
}
#endif

#endif /* DKVideoFeedTable_h */
