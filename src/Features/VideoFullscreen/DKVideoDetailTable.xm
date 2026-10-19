//
//  DKVideoDetailTable.xm
//  详情页在建行和分页计算前准备视频表，让原生行位置与 Cell 使用相同高度。
//

#import "DouyinHeaders.h"
#import "DKVideoFeedTable.h"
#import "DKVideoFullscreen.h"
#import <math.h>
#import <objc/runtime.h>

static BOOL gDKDetailHooksInstalled;
static const CGFloat kDKDetailHeightTolerance = 0.5;
static NSUInteger gDKDetailPrepareRuns;
static NSUInteger gDKDetailPrepareChanges;
struct DKDetailHeightStats {
    NSUInteger runs;
    NSUInteger changes;
};
static DKDetailHeightStats gDKDetailFixedStats = {};
static DKDetailHeightStats gDKDetailIndexStats = {};
static DKDetailHeightStats gDKDetailRowStats = {};
// 分页偏移被换算回统一页高的次数。为 0 说明抖音没走那条混算，
// 持续增长且偏移仍错，说明换算的式子要按新版本重新核对。
static NSUInteger gDKDetailOffsetChanges = 0;
// 反向（偏移→下标）被纠正的次数。它管的是「点 A 进 B」那一类错位：
// 正向偏移改了、反查没改，下标就会与行矩形错开。
static NSUInteger gDKDetailIndexChanges = 0;

static void DKPrepareDetailTable(AWEAwemeDetailTableViewController *controller,
                                 UITableView *table) {
    if (!DKVideoFullscreenOn()) return;
    gDKDetailPrepareRuns++;
    if (DKVideoFeedTablePrepareForController(controller, table)) {
        gDKDetailPrepareChanges++;
    }
}

// 仅统一已接管表中的整页行高；原生特殊行、自动尺寸和未就绪尺寸继续使用原返回值。
static double DKDetailRowHeight(UITableView *table, double nativeHeight,
                                DKDetailHeightStats *stats) {
    if (!DKVideoFullscreenOn() || !NSThread.isMainThread) return nativeHeight;
    stats->runs++;
    NSNumber *original = DKVideoFeedTableOriginalHeight(table);
    CGFloat target = CGRectGetHeight(table.bounds);
    if (!original || !isfinite(nativeHeight) || !isfinite(target)
        || nativeHeight <= 0.0 || target <= original.doubleValue + kDKDetailHeightTolerance) {
        return nativeHeight;
    }
    if (fabs(nativeHeight - original.doubleValue) > kDKDetailHeightTolerance
        && fabs(nativeHeight - target) > kDKDetailHeightTolerance) {
        return nativeHeight;
    }
    if (fabs(nativeHeight - target) > kDKDetailHeightTolerance) stats->changes++;
    return target;
}

NSString *DKVideoDetailTableStats(void) {
    return [NSString stringWithFormat:
        @"详情行高 Hook=%@  详情建行前准备 跑=%lu 补正=%lu  固定行高 跑=%lu 修正=%lu  "
         "索引行高 跑=%lu 修正=%lu  表代理行高 跑=%lu 修正=%lu  分页偏移换算=%lu  反查下标换算=%lu",
        gDKDetailHooksInstalled ? @"已安装" : @"入口缺失",
        (unsigned long)gDKDetailPrepareRuns, (unsigned long)gDKDetailPrepareChanges,
        (unsigned long)gDKDetailFixedStats.runs, (unsigned long)gDKDetailFixedStats.changes,
        (unsigned long)gDKDetailIndexStats.runs, (unsigned long)gDKDetailIndexStats.changes,
        (unsigned long)gDKDetailRowStats.runs, (unsigned long)gDKDetailRowStats.changes,
        (unsigned long)gDKDetailOffsetChanges, (unsigned long)gDKDetailIndexChanges];
}

%group DKVideoDetailTableHooks

%hook AWEAwemeDetailTableViewController

- (void)setupDetailTableView {
    %orig;
    if (DKVideoFullscreenOn()) DKPrepareDetailTable(self, self.tableView);
}

- (void)viewWillLayoutSubviews {
    if (DKVideoFullscreenOn()) DKPrepareDetailTable(self, self.tableView);
    %orig;
    if (DKVideoFullscreenOn()) DKPrepareDetailTable(self, self.tableView);
}

- (double)fixedCellHeight {
    if (!DKVideoFullscreenOn()) return %orig;
    UITableView *table = self.tableView;
    DKPrepareDetailTable(self, table);
    double nativeHeight = %orig;
    return DKDetailRowHeight(table, nativeHeight, &gDKDetailFixedStats);
}

- (double)cellHeightAtIndex:(long long)index {
    if (!DKVideoFullscreenOn()) return %orig;
    UITableView *table = self.tableView;
    DKPrepareDetailTable(self, table);
    double nativeHeight = %orig;
    return DKDetailRowHeight(table, nativeHeight, &gDKDetailIndexStats);
}

- (double)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!DKVideoFullscreenOn()) return %orig;
    DKPrepareDetailTable(self, table);
    double nativeHeight = %orig;
    return DKDetailRowHeight(table, nativeHeight, &gDKDetailRowStats);
}

// 分页偏移必须与行高用同一把尺子，否则每翻一页差一个底栏，而且**按页号累加**。
//
// 两次实测（440×956，底栏 83）都精确满足同一条式子：
//   offset = index × 873 + 956
//   第 2 页 2702 = 2×873 + 956；第 6 页 5321 = 5×873 + 956
// 也就是：前面 index 行仍按「撑高前 873」累计，只有当前这一行用撑高后的 956。
// 而各行真实矩形是 index × 956（第 2 行 1912、第 5 行 4780）——行高入口已经把行高统一成
// 956，偏移却按 873 累加，于是每翻一页偏 83，翻到第 n 页偏 n×83。
// 这既解释了「点一个退一个，偏移越来越严重」，也解释了「点 A 进 B」：抖音用
// indexForContentOffsetY: 反查偏移对应的下标，偏移与行矩形错开后，反查出的下标与手指点的
// 那个格子就不再是同一个，于是进的是另一条视频，且与空间位置无关。
//
// 修法不猜抖音的算式，直接问表自己：这一行的矩形原点在哪，偏移就该在哪。
// 表是行几何的唯一权威，我们的行高改动已经体现在它身上，换算自然跟着一致。
- (double)contentOffsetYForCellAtIndex:(long long)index {
    if (!DKVideoFullscreenOn()) return %orig;
    UITableView *table = self.tableView;
    DKPrepareDetailTable(self, table);

    double nativeOffset = %orig;
    if (!table || !isfinite(nativeOffset) || index < 0) return nativeOffset;

    CGFloat cellHeight = CGRectGetHeight(table.bounds);
    if (!isfinite(cellHeight) || cellHeight <= 0.0) return nativeOffset;

    NSInteger sections = [table numberOfSections];
    if (sections != 1) return nativeOffset;   // 多段表不套用这套「一页一行」的几何
    if (index >= [table numberOfRowsInSection:0]) return nativeOffset;

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
    CGRect row = [table rectForRowAtIndexPath:indexPath];
    if (CGRectIsNull(row) || !isfinite(row.origin.y)) return nativeOffset;

    // 只处理「一行就是一页」的表；其余（特殊行、未就绪尺寸）原样放行。
    if (fabs(CGRectGetHeight(row) - cellHeight) > kDKDetailHeightTolerance) return nativeOffset;

    CGFloat target = row.origin.y;
    if (fabs(target - nativeOffset) <= kDKDetailHeightTolerance) return nativeOffset;

    gDKDetailOffsetChanges++;
    return target;
}

- (void)adjustTableViewHeightForTargetIndex:(long long)index {
    if (DKVideoFullscreenOn()) DKPrepareDetailTable(self, self.tableView);
    %orig;
    if (DKVideoFullscreenOn()) DKPrepareDetailTable(self, self.tableView);
}

// 反查方向：偏移 → 下标。抖音用它把 contentOffset 换成「现在是第几条」，
// 点格子进详情时也走这条。正向换算已经改成行矩形，若反查仍按 index×873+956 的形状去套，
// 就会算出一个偏大 83×index 的下标，于是「点 A 进 B」，而且点得越靠后越离谱。
//
// 这里直接把偏移落到表自己的行矩形上：落在哪一行，就是那一行。
// 一行对应一页时才接管，其余（特殊行、多段表）原样放行。
- (double)indexForContentOffsetY:(double)offsetY {
    if (!DKVideoFullscreenOn()) return %orig;

    UITableView *table = self.tableView;
    DKPrepareDetailTable(self, table);

    double nativeIndex = %orig;
    if (!table || !isfinite(offsetY) || [table numberOfSections] != 1) return nativeIndex;

    CGFloat cellHeight = CGRectGetHeight(table.bounds);
    if (!isfinite(cellHeight) || cellHeight <= 0.0) return nativeIndex;

    // 抖音在这套表里用整数下标 + 一页一行的几何；按行矩形反算。
    double rowIndex = floor((offsetY + kDKDetailHeightTolerance) / cellHeight);
    if (!isfinite(rowIndex) || rowIndex < 0.0) return nativeIndex;

    NSInteger rows = [table numberOfRowsInSection:0];
    if (rows <= 0) return nativeIndex;
    if (rowIndex > (double)(rows - 1)) rowIndex = (double)(rows - 1);

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:(NSInteger)rowIndex inSection:0];
    CGRect row = [table rectForRowAtIndexPath:indexPath];
    if (CGRectIsNull(row)) return nativeIndex;
    // 行高不是整页 → 不是这套几何，原样放行。
    if (fabs(CGRectGetHeight(row) - cellHeight) > kDKDetailHeightTolerance) return nativeIndex;

    double target = rowIndex;
    if (fabs(target - nativeIndex) <= kDKDetailHeightTolerance) return nativeIndex;

    gDKDetailIndexChanges++;
    return target;
}

%end

%end

%ctor {
    Class controllerClass = NSClassFromString(@"AWEAwemeDetailTableViewController");
    SEL selectors[] = {
        @selector(setupDetailTableView), @selector(viewWillLayoutSubviews),
        @selector(fixedCellHeight), @selector(cellHeightAtIndex:),
        @selector(tableView:heightForRowAtIndexPath:),
        @selector(contentOffsetYForCellAtIndex:),
        @selector(indexForContentOffsetY:),
        @selector(adjustTableViewHeightForTargetIndex:)
    };
    for (SEL selector : selectors) {
        if (!class_getInstanceMethod(controllerClass, selector)) return;
    }
    %init(DKVideoDetailTableHooks);
    gDKDetailHooksInstalled = YES;
}
