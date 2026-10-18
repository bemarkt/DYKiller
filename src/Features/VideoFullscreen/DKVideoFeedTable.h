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

/// 把停在页中间的翻页偏移按行几何对齐到整页。停稳时才动，非整页表不动。
///
/// 实测现场（0.6.2 / 40.7.0 / 440×956）：行矩形精确落在 1912 与 2868（= 2·956 / 3·956），
/// contentSize 20076 = 21·956，而 contentOffset 是 2702 = 873×3 + 83——既不是 956 的倍数，
/// 也不是 873 的倍数。直播间进出时抖音按「底栏占位那一版」算出的偏移与整屏行高混在一起，
/// 视口顶边落在第 2 行内部、下方还露出第 3 行上沿，表现就是「视频上移」。
/// 偏移只被消费一次，没有任何一次 frame 写入会回头复核，只能按行矩形拉回。
BOOL DKVideoFeedTableSnapPagedOffset(UITableView *table);

/// 翻页偏移现场：当前 offsetY、视口高、内容高与页数、落在哪一行与该行行顶/行高。
/// 供探针确认「偏移不是任何一整页的倍数」这类现场，下次换机型不用重新推断。
NSString *DKVideoFeedTableOffsetStats(UITableView *table);

/// HUD 钉位与视频表修正的会话累计统计；首页和详情控制器布局分别报告调用与补正次数。
NSString *DKVideoFeedTableStats(void);

#ifdef __cplusplus
}
#endif

#endif /* DKVideoFeedTable_h */
