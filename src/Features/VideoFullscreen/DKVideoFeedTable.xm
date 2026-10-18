//
//  DKVideoFeedTable.xm
//  「视频表被底栏压掉一个底栏高」这一类裁剪源头的修正：撑高表，再把 HUD 钉回撑高前的高度。
//
// 表与 Cell 的高度由视频表规则和详情页行高入口共同准备；HUD 按原高保留底部锚定位置。
//
//  作用域是基类 AWEFeedDataSafeTableView，不是某一页：
//
//      AWEFeedTableView        : AWEFeedDataSafeTableView   （首页 / 朋友页）
//      AWEAwemeDetailTableView : AWEFeedDataSafeTableView   （好友聊天 / 搜索 / 其他用户主页）
//
//  同一个基类下这两种表都可能被压缩，也都可能本来就是满高，所以判据放在基类上，
//  再由「容器比表更高」这个结构条件决定要不要撑——满高的表天然跳过，新增子类也自动覆盖。
//
//  视频容器本身不归本文件管：它在所有页面遵循同一条规则，定义与拦截都在 DKVideoGeometry.xm。
//
//  HUD 钉位保留两条路径，各有职责，缺一不可：
//    · 拦 setFrame: —— 写入时就改值，抖音读回来即是钉后的值，不会逐帧拉扯，也没有闪烁；
//    · 布局后兜底 —— HUD 有相当一部分 frame 写入发生在它还没进入视图层级、取不到原高的时刻，
//      那些写入只能放行，靠这一步在布局结束后补正。
//  （实测 setBounds:/setCenter: 两条通道命中数恒为 0，未挂。）
//

#import "DKVideoFeedTable.h"
#import "DKVideoFullscreen.h"
#import "DouyinHeaders.h"
#import <objc/runtime.h>
#import <math.h>

// 覆盖 @3x 像素对齐带来的亚像素漂移。
static const CGFloat kDKFeedTolerance = 0.5;
// 表高至少要到容器的这个比例才认作「已排好、只差一个底栏」，排除布局早期的半成品尺寸。
static const CGFloat kDKFeedMinHeightRatio = 0.5;
// 从 HUD 往上找视频表的最大层数（图文内容多两层容器，取 8 有余量）。
static const NSUInteger kDKFeedAncestorLimit = 8;

// 撑高前的表高。挂在表上，既是还原依据，也是 HUD 的钉位目标。
static char kDKFeedOriginalHeightKey;
// 所有撑高过的表（弱引用），供关闭开关时立即还原。多页并存时可能不止一张。
static NSHashTable<UITableView *> *gStretchedTables = nil;

#pragma mark - 命中统计

// 这两个数一起看才有意义：写入时拦截 vs 布局后兜底。首页/朋友页实测比例约 130:6，
// 是「写入时拦截不能砍成事后纠正」的直接依据。
static NSUInteger gHitSetFrame = 0;
static NSUInteger gHitFallback = 0;
// 40.7.0 的旧表写入入口。与新版控制器布局补正分开统计，用于后续判断旧逻辑是否仍有贡献。
static NSUInteger gHitTableSetFrame = 0;
// 控制器布局完成后补正已进入视图树的子表，并分别统计首页与详情入口。
static NSUInteger gHitTableLayout = 0;
struct DKFeedTableLayoutStats {
    NSUInteger runs;
    NSUInteger adjustments;
};
static DKFeedTableLayoutStats gFeedTableLayoutStats = {};
static DKFeedTableLayoutStats gDetailTableLayoutStats = {};

NSString *DKVideoFeedTableStats(void) {
    return [NSString stringWithFormat:
            @"HUD setFrame=%lu  HUD 布局后兜底=%lu  表 setFrame补正=%lu  表控制器布局补正=%lu  "
             "首页控制器布局 跑=%lu 补正=%lu  详情控制器布局 跑=%lu 补正=%lu",
            (unsigned long)gHitSetFrame,
            (unsigned long)gHitFallback,
            (unsigned long)gHitTableSetFrame,
            (unsigned long)gHitTableLayout,
            (unsigned long)gFeedTableLayoutStats.runs,
            (unsigned long)gFeedTableLayoutStats.adjustments,
            (unsigned long)gDetailTableLayoutStats.runs,
            (unsigned long)gDetailTableLayoutStats.adjustments];
}

#pragma mark - 目标判定

Class DKVideoFeedTableClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"AWEFeedDataSafeTableView"); });
    return cls;
}

UIView *DKFeedTableForView(UIView *view) {
    Class tableCls = DKVideoFeedTableClass();
    if (!tableCls) return nil;

    UIView *ancestor = view.superview;
    for (NSUInteger i = 0; ancestor && i < kDKFeedAncestorLimit; i++, ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:tableCls]) return ancestor;
    }
    return nil;
}

NSNumber *DKVideoFeedTableOriginalHeight(UIView *table) {
    return objc_getAssociatedObject(table, &kDKFeedOriginalHeightKey);
}

// 该视图所在视频表撑高前的高度，也就是 HUD 的钉位目标；不在撑高作用域内返回 0。
static CGFloat DKFeedOriginalHeight(UIView *view) {
    if (!DKVideoFullscreenOn()) return 0.0;
    return DKVideoFeedTableOriginalHeight(DKFeedTableForView(view)).doubleValue;
}

#pragma mark - 翻页偏移对齐

// 把停在「页中间」的偏移按行几何对齐到整页。
//
// 这是「进过直播间回来，博主主页的视频上移」的直接病灶。实测现场（0.6.2 / 40.7.0 / 440×956）：
//   cell 高 956，行矩形精确落在 1912 与 2868（= 2·956 / 3·956），contentSize 20076 = 21·956；
//   可 contentOffset 是 2702，而 2702 = 873×3 + 83，既不是 956 的倍数也不是 873 的倍数。
// 行按整屏页高排、偏移按「底栏占位那一版」翻页再叠一个底栏，于是视口顶边落在第 2 行内部：
// 上面露出 166pt 的上一页、下面露出第 3 行的绝大部分——用户看到的就是视频整体上移。
//
// 偏移不是我们写的，是直播间进出时抖音自己算的：进直播间底栏让位、页高从 873 变 956，
// 退出后行高回到整屏，偏移却留着旧倍数的残值。它只被消费一次，没有任何一次 frame 写入
// 会回头复核，所以只能在停稳之后按行矩形拉回来。
//
// 守卫都按结构判定，不靠「记住曾经多高」那种软信号（首帧根本没有历史可比）：
//   · 拖动 / 惯性 / 跟踪期间不动，否则与手势互相拉扯；
//   · 内容高度必须是视口高的整数倍——有表头、有尾条的页面倍数对不上，一律不碰，
//     这类页面的偏移本来就含表头量，对齐到行顶反而会跳；
//   · 只处理「一行就是一页」的表（好友聊天、搜索那种列表行不是整页）；
//   · 只对齐到最近的行顶，且本来就在行顶时不动，避免每轮布局写入同一个值。
BOOL DKVideoFeedTableSnapPagedOffset(UITableView *table) {
    if (!table || !DKVideoFullscreenOn()) return NO;
    if (table.isDragging || table.isDecelerating || table.isTracking) return NO;

    CGFloat viewport = CGRectGetHeight(table.bounds);
    if (!isfinite(viewport) || viewport <= 0.0) return NO;

    CGPoint offset = table.contentOffset;
    if (!isfinite(offset.y) || offset.y <= 0.0) return NO;

    CGFloat contentHeight = table.contentSize.height;
    if (!isfinite(contentHeight) || contentHeight <= 0.0) return NO;

    // 内容高度不是视口整数倍 → 有表头 / 尾条 / 非常规行，偏移里本来就有额外量。
    double pages = round(contentHeight / viewport);
    if (pages < 1.0 || fabs(contentHeight - pages * viewport) > kDKFeedTolerance) return NO;

    // 取行顶离当前偏移最近的那一行：用户正看着的那一页不动，只把跨页的那半格对齐回来。
    NSIndexPath *containing = [table indexPathForRowAtPoint:CGPointMake(0.0, offset.y + 1.0)];
    if (!containing) return NO;

    CGRect row = [table rectForRowAtIndexPath:containing];
    if (CGRectIsNull(row) || !isfinite(row.origin.y)) return NO;

    // 一行就是一页；列表型行高对这个页面没有意义，动了反而是错。
    CGFloat rowHeight = CGRectGetHeight(row);
    if (rowHeight <= 0.0 || fabs(rowHeight - viewport) > kDKFeedTolerance) return NO;

    CGFloat target = row.origin.y;
    CGFloat nearest = fabs(target - offset.y);
    NSInteger rowsInSection = [table numberOfRowsInSection:containing.section];
    for (NSInteger step = -1; step <= 1; step += 2) {
        NSInteger neighbour = containing.row + step;
        if (neighbour < 0 || neighbour >= rowsInSection) continue;

        NSIndexPath *path = [NSIndexPath indexPathForRow:neighbour inSection:containing.section];
        CGRect candidate = [table rectForRowAtIndexPath:path];
        if (CGRectIsNull(candidate)) continue;

        CGFloat distance = fabs(candidate.origin.y - offset.y);
        if (distance < nearest) {
            nearest = distance;
            target = candidate.origin.y;
        }
    }

    if (fabs(target - offset.y) <= kDKFeedTolerance) return NO;

    // 夹进合法的偏移区间：末页对齐到行顶可能超出底部，扣掉内缩后再兜一次。
    UIEdgeInsets insets = table.adjustedContentInset;
    CGFloat maxOffset = contentHeight - viewport + insets.bottom;
    CGFloat minOffset = -insets.top;
    if (isfinite(maxOffset) && maxOffset > minOffset) target = MIN(target, maxOffset);
    target = MAX(target, minOffset);
    if (fabs(target - offset.y) <= kDKFeedTolerance) return NO;

    table.contentOffset = CGPointMake(offset.x, target);
    return YES;
}

// 翻页偏移现场：当前 offsetY、视口高、内容高与页数、落在哪一行与该行行顶/行高。
// 供探针确认「偏移不是任何一整页的倍数」这类现场，下次换机型不用重新推断。
NSString *DKVideoFeedTableOffsetStats(UITableView *table) {
    if (!table) return @"(无表)";

    CGPoint offset = table.contentOffset;
    CGFloat viewport = CGRectGetHeight(table.bounds);
    CGFloat contentHeight = table.contentSize.height;

    NSIndexPath *indexPath = [table indexPathForRowAtPoint:CGPointMake(0.0, offset.y + 1.0)];
    CGRect row = indexPath ? [table rectForRowAtIndexPath:indexPath] : CGRectNull;

    double pages = viewport > 0.0 ? contentHeight / viewport : 0.0;

    return [NSString stringWithFormat:
        @"offsetY=%.0f  视口=%.0f  内容高=%.0f（%.2f 页）  落在行=%@ 行顶=%.0f 行高=%.0f  "
         "离行顶=%.0f",
        offset.y,
        viewport,
        contentHeight,
        pages,
        indexPath ?: (id)@"(无)",
        CGRectIsNull(row) ? 0.0 : CGRectGetMinY(row),
        CGRectIsNull(row) ? 0.0 : CGRectGetHeight(row),
        CGRectIsNull(row) ? 0.0 : fabs(CGRectGetMinY(row) - offset.y)];
}

#pragma mark - 撑高视频表

// 共享撑高规则同时供表写入与控制器布局入口调用。首页表自己实现 setFrame:，
// 详情表继承基类的写入入口；已达到目标高度的写入直接放行。
static CGRect DKFeedTableAdjustFrameToHeight(UITableView *table, CGRect frame, CGFloat target) {
    if (!DKVideoFullscreenOn()) {
        // 关闭后一律放行，抖音写什么就是什么；标记清掉以免 HUD 继续被钉。
        objc_setAssociatedObject(table, &kDKFeedOriginalHeightKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return CGRectNull;
    }

    CGFloat current = CGRectGetHeight(frame);
    // 容器不比来意的高度更高 → 这张表没被底栏压缩过（搜索页、好友聊天页就是这种），不在作用域内；
    // 高度不到容器一半 → 布局早期的半成品，记下它会把 HUD 钉到错误的位置。
    if (!isfinite(target) || !isfinite(current)
        || target <= 0.0
        || current >= target - kDKFeedTolerance
        || current < target * kDKFeedMinHeightRatio) {
        return CGRectNull;
    }

    if (!objc_getAssociatedObject(table, &kDKFeedOriginalHeightKey)) {
        objc_setAssociatedObject(table, &kDKFeedOriginalHeightKey, @(current),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gStretchedTables addObject:table];
    }
    frame.size.height = target;
    return frame;
}

CGRect DKVideoFeedTableAdjustFrame(UITableView *table, CGRect frame) {
    return DKFeedTableAdjustFrameToHeight(table, frame,
        CGRectGetHeight(table.superview.bounds));
}

// 详情表在建行前可能尚未挂入父视图，此时取已加载控制器根视图的高度。
// 首次写表尺寸之前记录真实原高，供首个 Cell 的 HUD 钉位使用。
BOOL DKVideoFeedTablePrepareForController(UIViewController *controller, UITableView *table) {
    if (!DKVideoFullscreenOn() || !NSThread.isMainThread || !table) return NO;
    Class tableClass = DKVideoFeedTableClass();
    UIView *root = controller.viewIfLoaded;
    if (!tableClass || ![table isKindOfClass:tableClass] || !root) return NO;
    UIWindow *window = table.window ?: root.window;
    if (window && window.windowLevel != UIWindowLevelNormal) return NO;
    if (table.superview && ![table isDescendantOfView:root]) return NO;
    if (!CGAffineTransformIsIdentity(table.transform)) return NO;

    CGFloat target = table.superview
        ? CGRectGetHeight(table.superview.bounds) : CGRectGetHeight(root.bounds);
    CGRect adjusted = DKFeedTableAdjustFrameToHeight(table, table.frame, target);
    if (CGRectIsNull(adjusted)) return NO;
    table.frame = adjusted;
    return YES;
}

// 在写入时就改成满高：抖音把表高改回原值（如关闭评论区）的那一刻即被顶回去，
// 不必等下一次布局。事后在 layoutSubviews 里改会留下「切一下才恢复」的空窗。
%hook AWEFeedDataSafeTableView

- (void)setFrame:(CGRect)frame {
    CGRect adjusted = DKVideoFeedTableAdjustFrame(self, frame);
    if (CGRectIsNull(adjusted)) {
        %orig;
        return;
    }
    gHitTableSetFrame++;
    %orig(adjusted);
}

%end

%hook AWEFeedTableView

- (void)setFrame:(CGRect)frame {
    CGRect adjusted = DKVideoFeedTableAdjustFrame(self, frame);
    if (CGRectIsNull(adjusted)) {
        %orig;
        return;
    }
    gHitTableSetFrame++;
    %orig(adjusted);
}

%end

// 控制器完成原生布局后，子表已进入视图树，可以读取父容器高度。
// 两套控制器共用撑高规则；仅在目标未满足时修改子表 frame。
// 顺带把停在页中间的翻页偏移按行几何拉回整页：偏移只被消费一次，
// 布局后不复核就永远是错的（这是「进过直播间回来视频上移」留下的那份残值）。
static void DKSyncFeedTableLayout(UITableView *table, DKFeedTableLayoutStats *stats) {
    stats->runs++;
    if (!table) return;

    CGRect adjusted = DKVideoFeedTableAdjustFrame(table, table.frame);
    if (!CGRectIsNull(adjusted)) {
        table.frame = adjusted;
        gHitTableLayout++;
        stats->adjustments++;
    }
    DKVideoFeedTableSnapPagedOffset(table);
}

%hook AWEFeedTableViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (!DKVideoFullscreenOn()) return;
    DKSyncFeedTableLayout(self.tableView, &gFeedTableLayoutStats);
}

%end

%hook AWEAwemeDetailTableViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (!DKVideoFullscreenOn()) return;
    DKSyncFeedTableLayout(self.tableView, &gDetailTableLayoutStats);
}

%end

#pragma mark - HUD 钉位

// 由 DKVideoGeometry.xm 的总入口调用，调用方已确认写入方是 AWEPlayInteractionViewController。
// HUD 根视图是裸 UIView、没有类可挂，只能这样拦。返回 CGRectNull 表示放行。
//
// 不在已撑高的表内就在这里放行——那种页面的 HUD 本来就该跟着页面走；误钉成 Cell 满高会让
// 好友聊天页的文案/昵称/点赞栏整体下移一个底栏高。
CGRect DKFeedHUDAdjustFrame(UIView *view, CGRect frame) {
    if (!DKVideoFullscreenOn()) return CGRectNull;

    UIView *table = DKFeedTableForView(view);
    if (!table) return CGRectNull;

    NSNumber *original = DKVideoFeedTableOriginalHeight(table);
    if (!original) return CGRectNull;

    // 只拦「被设成撑高后的满高」这一种写入；缩小态（如评论展开）一律放行。
    CGFloat pinned = original.doubleValue;
    if (CGRectGetHeight(frame) <= pinned + kDKFeedTolerance) return CGRectNull;

    gHitSetFrame++;
    frame.size.height = pinned;
    return frame;
}

// 补正那些在取不到原高的时刻被放行的写入，布局结束后拉回「顶边贴合、高度为原高」。
// 不是冗余兜底：实测每页仍有 4~11 次命中，是 HUD 尚未进入视图层级那几次写入的唯一出路。
//
// DKVideoPageChrome.xm 也在同一个方法上挂了一层（顶部黑遮罩同步），这是有意分开的：
// 两件事分属两个功能，各自跟着自己的模块走，删掉任一模块另一个都不受影响。多层 %hook 会
// 正常串联，装机版本上两条同时生效。
%hook AWEPlayInteractionViewController

- (void)viewDidLayoutSubviews {
    %orig;

    // 已经在 HUD 控制器内部，不必再判类型。
    UIView *view = self.viewIfLoaded;
    if (!view) return;

    CGFloat original = DKFeedOriginalHeight(view);
    if (original <= 0.0) return;

    CGRect frame = view.frame;
    if (fabs(CGRectGetMinY(frame)) <= kDKFeedTolerance
        && CGRectGetHeight(frame) <= original + kDKFeedTolerance) {
        return;
    }

    view.frame = CGRectMake(CGRectGetMinX(frame), 0.0, CGRectGetWidth(frame), original);
    gHitFallback++;
}

%end

#pragma mark - 还原

// 关闭开关时立刻把表高还回去，不必等抖音下一次写 frame。
static void DKVideoFeedTableRestore(void) {
    for (UITableView *table in gStretchedTables.allObjects) {
        NSNumber *original = DKVideoFeedTableOriginalHeight(table);
        if (!original) continue;

        objc_setAssociatedObject(table, &kDKFeedOriginalHeightKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGRect frame = table.frame;
        frame.size.height = original.doubleValue;
        table.frame = frame;
    }
    [gStretchedTables removeAllObjects];
}

%ctor {
    gStretchedTables = [NSHashTable weakObjectsHashTable];
    DKVideoFullscreenRegisterRestore(DKVideoFeedTableRestore);
}
