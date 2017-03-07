/**
 * Created by Weex.
 * Copyright (c) 2016, Alibaba, Inc. All rights reserved.
 *
 * This source code is licensed under the Apache Licence 2.0.
 * For the full copyright and license information,please view the LICENSE file in the root directory of this source tree.
 */

#import "WXRecyclerUpdateController.h"
#import "WXCellComponent.h"
#import "WXAssert.h"
#import "WXLog.h"
#import "WXDiffUtil.h"
#import "NSArray+Weex.h"

@interface WXRecyclerDiffResult : NSObject

@property (nonatomic, strong, readonly) NSIndexSet *insertSections;
@property (nonatomic, strong, readonly) NSIndexSet *deleteSections;
@property (nonatomic, strong, readonly) NSIndexSet *reloadSections;

@property (nonatomic, strong, readonly) NSMutableSet<NSIndexPath *> *deleteIndexPaths;
@property (nonatomic, strong, readonly) NSMutableSet<NSIndexPath *> *insertIndexPaths;
@property (nonatomic, strong, readonly) NSMutableSet<NSIndexPath *> *reloadIndexPaths;

- (BOOL)hasChanges;

@end

@implementation WXRecyclerDiffResult

- (instancetype)initWithInsertSections:(NSIndexSet *)insertSections
                        deleteSections:(NSIndexSet *)deletesSections
                        reloadSections:(NSIndexSet *)reloadSections
                      insertIndexPaths:(NSMutableSet<NSIndexPath *> *)insertIndexPaths
                      deleteIndexPaths:(NSMutableSet<NSIndexPath *> *)deleteIndexPaths
                      reloadIndexPaths:(NSMutableSet<NSIndexPath *> *)reloadIndexPaths
{
    if (self = [super init]) {
        _insertSections = [insertSections copy];
        _deleteSections = [deletesSections copy];
        _reloadSections = [reloadSections copy];
        _insertIndexPaths = [insertIndexPaths copy];
        _deleteIndexPaths = [deleteIndexPaths copy];
        _reloadIndexPaths = [reloadIndexPaths copy];
    }
    
    return self;
}

- (BOOL)hasChanges
{
    return _insertSections.count > 0 || _deleteSections.count > 0 || _reloadSections.count > 0 || _insertIndexPaths.count > 0 || _deleteIndexPaths.count > 0 || _reloadIndexPaths.count > 0;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p; insert sections: %@; delete sections: %@; reload sections: %@; insert index paths: %@; delete index paths: %@; reload index paths: %@", NSStringFromClass([self class]), self,_insertSections, _deleteSections, _reloadSections, _insertIndexPaths, _deleteIndexPaths, _reloadIndexPaths];
}

@end

@interface WXRecyclerUpdateController ()

@property (nonatomic, copy) NSArray<WXSectionDataController *> *theNewData;
@property (nonatomic, copy) NSArray<WXSectionDataController *> *theOldData;
@property (nonatomic, weak) UICollectionView *collectionView;
@property (nonatomic, strong) NSMutableSet<NSIndexPath *> *reloadIndexPaths;
@property (nonatomic, assign) BOOL isUpdating;

@end

@implementation WXRecyclerUpdateController

- (void)performUpdatesWithNewData:(NSArray<WXSectionDataController *> *)newData oldData:(NSArray<WXSectionDataController *> *)oldData view:(UICollectionView *)collectionView
{
    if (!collectionView) {
        return;
    }
    
    self.theNewData = newData;
    self.theOldData = oldData;
    self.collectionView = collectionView;
    
    [self checkUpdates];
}

- (void)reloadItemsAtIndexPath:(NSIndexPath *)indexPath
{
    if (!indexPath) {
        return;
    }
    
    if (!_reloadIndexPaths) {
        _reloadIndexPaths = [NSMutableSet set];
    }
    
    [_reloadIndexPaths addObject:indexPath];
    
    [self checkUpdates];
}

- (void)checkUpdates
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.isUpdating) {
            return ;
        }
        
        [self performBatchUpdates];
    });
}

- (void)performBatchUpdates
{
    WXAssertMainThread();
    WXAssert(!self.isUpdating, @"Can not perform updates while an updating is being performed");
    
    UICollectionView *collectionView = self.collectionView;
    if (!collectionView) {
        return;
    }
    
    NSArray<WXSectionDataController *> *newData = [self.theNewData copy];
    NSArray<WXSectionDataController *> *oldData = [self.theOldData copy];

    [self cleanup];
    
    WXRecyclerDiffResult *diffResult = [self diffWithNewData:newData oldData:oldData];
    if (![diffResult hasChanges] && self.reloadIndexPaths.count == 0) {
        return;
    }
    
    void (^updates)() = [^{
        [self.delegate updateController:self willPerformUpdateWithNewData:newData];
        [UIView setAnimationsEnabled:NO];
        WXLogDebug(@"UICollectionView update:%@", diffResult);
        [self applyUpdate:diffResult toCollectionView:self.collectionView];
    } copy];
    
    void (^completion)(BOOL) = [^(BOOL finished) {
        [UIView setAnimationsEnabled:YES];
        self.isUpdating = NO;
        [self.delegate updateController:self didPerformUpdateWithFinished:finished];
        [self.reloadIndexPaths removeAllObjects];
        [self checkUpdates];
    } copy];
    
    self.isUpdating = YES;
    
    if (!self.delegate) {
        return;
    }
    
    WXLogDebug(@"Diff result:%@", diffResult);
    @try {
        [collectionView performBatchUpdates:updates completion:completion];
    } @catch (NSException *exception) {
        [self.delegate updateController:self willCrashWithException:exception oldData:oldData newData:newData];
        @throw exception;
    }
}

- (void)cleanup
{
    self.theNewData = nil;
    self.theOldData = nil;
}

- (WXRecyclerDiffResult *)diffWithNewData:(NSArray<WXSectionDataController *> *)newData
                              oldData:(NSArray<WXSectionDataController *> *)oldData
{
    NSMutableIndexSet *reloadSections = [NSMutableIndexSet indexSet];
    NSMutableSet<NSIndexPath *> *reloadIndexPaths = [NSMutableSet set];
    NSMutableSet<NSIndexPath *> *deleteIndexPaths = [NSMutableSet set];
    NSMutableSet<NSIndexPath *> *insertIndexPaths = [NSMutableSet set];
    
    WXDiffResult *sectionDiffResult = [WXDiffUtil diffWithMinimumDistance:newData oldArray:oldData];
    
    WXLogDebug(@"section diff result:%@", sectionDiffResult);
    
    [sectionDiffResult.inserts enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
        WXSectionDataController *newSection = [newData wx_safeObjectAtIndex:idx];
        [newSection.cellComponents enumerateObjectsUsingBlock:^(WXCellComponent * _Nonnull obj, NSUInteger idx2, BOOL * _Nonnull stop) {
            if (obj.isLayoutComplete) {
                NSIndexPath *insertIndexPath = [NSIndexPath indexPathForItem:idx2 inSection:idx];
                [insertIndexPaths addObject:insertIndexPath];
            }
        }];
        WXAssert(newSection, @"No section found in  new index:%ld");
    }];
    
    for (WXDiffUpdateIndex *sectionUpdate in sectionDiffResult.updates) {
        WXSectionDataController *oldSection = [oldData wx_safeObjectAtIndex:sectionUpdate.oldIndex];
        WXSectionDataController *newSection = [newData wx_safeObjectAtIndex:sectionUpdate.newIndex];
        WXAssert(newSection && oldSection, @"No section found in old index:%ld, new index:%ld", sectionUpdate.oldIndex, sectionUpdate.newIndex);
        
        WXDiffResult *itemDiffResult = [WXDiffUtil diffWithMinimumDistance:newSection.cellComponents oldArray:oldSection.cellComponents];
        if (![itemDiffResult hasChanges]) {
            // header or footer need to be updated
            [reloadSections addIndex:sectionUpdate.oldIndex];
        } else {
            for (WXDiffUpdateIndex *update in itemDiffResult.updates) {
                NSIndexPath *reloadIndexPath = [NSIndexPath indexPathForItem:update.oldIndex inSection:sectionUpdate.oldIndex];
                [reloadIndexPaths addObject:reloadIndexPath];
            }
            
            [itemDiffResult.inserts enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
                WXCellComponent *cell = [newSection.cellComponents wx_safeObjectAtIndex:idx];
                if (cell.isLayoutComplete) {
                    NSIndexPath *insertIndexPath = [NSIndexPath indexPathForItem:idx inSection:sectionUpdate.oldIndex];
                    [insertIndexPaths addObject:insertIndexPath];
                }
            }];
            
            [itemDiffResult.deletes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL * _Nonnull stop) {
                NSIndexPath *deleteIndexPath = [NSIndexPath indexPathForItem:idx inSection:sectionUpdate.oldIndex];
                [deleteIndexPaths addObject:deleteIndexPath];
            }];
        }
        
    }
    
    WXRecyclerDiffResult *result = [[WXRecyclerDiffResult alloc] initWithInsertSections:sectionDiffResult.inserts
                                                                 deleteSections:sectionDiffResult.deletes
                                                                 reloadSections:reloadSections
                                                               insertIndexPaths:insertIndexPaths
                                                               deleteIndexPaths:deleteIndexPaths
                                                               reloadIndexPaths:reloadIndexPaths];
    
    return result;
}

- (void)applyUpdate:(WXRecyclerDiffResult *)diffResult toCollectionView:(UICollectionView *)collectionView
{
    if (!collectionView) {
        return;
    }
    
    [collectionView deleteItemsAtIndexPaths:[diffResult.deleteIndexPaths allObjects]];
    [collectionView insertItemsAtIndexPaths:[diffResult.insertIndexPaths allObjects]];
    
    NSSet *reloadIndexPaths = self.reloadIndexPaths ? [diffResult.reloadIndexPaths setByAddingObjectsFromSet:self.reloadIndexPaths] : diffResult.reloadIndexPaths;
    
    [collectionView reloadItemsAtIndexPaths:[reloadIndexPaths allObjects]];
    
    [collectionView deleteSections:diffResult.deleteSections];
    [collectionView insertSections:diffResult.insertSections];
    [collectionView reloadSections:diffResult.reloadSections];
}

@end
