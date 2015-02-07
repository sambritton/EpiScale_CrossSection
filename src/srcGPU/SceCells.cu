#include "SceCells.h"

double epsilon = 1.0e-12;

__constant__ double membrEquLen;
__constant__ double membrStiff;

__device__
double calMembrForce(double& length) {
	return (length - membrEquLen) * membrStiff;
}

void SceCells::distributeBdryIsActiveInfo() {
	thrust::fill(nodes->getInfoVecs().nodeIsActive.begin(),
			nodes->getInfoVecs().nodeIsActive.begin()
					+ allocPara.startPosProfile, true);
}

void SceCells::distributeProfileIsActiveInfo() {
	thrust::fill(
			nodes->getInfoVecs().nodeIsActive.begin()
					+ allocPara.startPosProfile,
			nodes->getInfoVecs().nodeIsActive.begin()
					+ allocPara.startPosProfile
					+ nodes->getAllocPara().currentActiveProfileNodeCount,
			true);
}

void SceCells::distributeECMIsActiveInfo() {
	uint totalNodeCountForActiveECM = allocPara.currentActiveECM
			* allocPara.maxNodePerECM;
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::counting_iterator<uint> countingEnd(totalNodeCountForActiveECM);
	thrust::fill(
			nodes->getInfoVecs().nodeIsActive.begin() + allocPara.startPosECM,
			nodes->getInfoVecs().nodeIsActive.begin()
					+ totalNodeCountForActiveECM + allocPara.startPosECM, true);
}

void SceCells::distributeCellIsActiveInfo() {
	totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::counting_iterator<uint> countingEnd(totalNodeCountForActiveCells);

	thrust::transform(
			thrust::make_transform_iterator(countingBegin,
					ModuloFunctor(allocPara.maxNodeOfOneCell)),
			thrust::make_transform_iterator(countingEnd,
					ModuloFunctor(allocPara.maxNodeOfOneCell)),
			thrust::make_permutation_iterator(
					cellInfoVecs.activeNodeCountOfThisCell.begin(),
					make_transform_iterator(countingBegin,
							DivideFunctor(allocPara.maxNodeOfOneCell))),
			nodes->getInfoVecs().nodeIsActive.begin() + allocPara.startPosCells,
			thrust::less<uint>());
}

void SceCells::distributeCellGrowthProgress() {
	totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::counting_iterator<uint> countingEnd(totalNodeCountForActiveCells);

	thrust::copy(
			thrust::make_permutation_iterator(
					cellInfoVecs.growthProgress.begin(),
					make_transform_iterator(countingBegin,
							DivideFunctor(allocPara.maxNodeOfOneCell))),
			thrust::make_permutation_iterator(
					cellInfoVecs.growthProgress.begin(),
					make_transform_iterator(countingEnd,
							DivideFunctor(allocPara.maxNodeOfOneCell))),
			nodes->getInfoVecs().nodeGrowPro.begin() + allocPara.startPosCells);
}

SceCells::SceCells() {
}

/**
 * This is a method for cell growth. growth is influened by two chemical fields.
 * first step: assign the growth magnitude and direction info that was calculated outside
 *     to internal values
 *     please note that a cell should not grow if its type is boundary.
 *
 * second step: use the growth magnitude and dt to update growthProgress
 *
 * third step: use lastCheckPoint and growthProgress to decide whether add point or not
 *
 * fourth step: use growthProgress and growthXDir&growthYDir to compute
 *     expected length along the growth direction.
 *
 * fifth step:  reducing the smallest value and biggest value
 *     a cell's node to its center point
 *
 * sixth step: compute the current length and then
 *     compute its difference with expected length
 *
 * seventh step: use the difference that just computed and growthXDir&growthYDir
 *     to apply stretching force (velocity) on nodes of all cells
 *
 * eighth step: cell move according to the velocity computed
 *
 * ninth step: also add a point if scheduled to grow.
 *     This step does not guarantee success ; If adding new point failed, it will not change
 *     isScheduleToGrow and activeNodeCount;
 */
void SceCells::grow2DTwoRegions(double d_t, GrowthDistriMap &region1,
		GrowthDistriMap &region2) {
// obtain pointer address for first region
	growthAuxData.growthFactorMagAddress = thrust::raw_pointer_cast(
			&(region1.growthFactorMag[0]));
	growthAuxData.growthFactorDirXAddress = thrust::raw_pointer_cast(
			&(region1.growthFactorDirXComp[0]));
	growthAuxData.growthFactorDirYAddress = thrust::raw_pointer_cast(
			&(region1.growthFactorDirYComp[0]));

// obtain pointer address for second region
	growthAuxData.growthFactorMagAddress2 = thrust::raw_pointer_cast(
			&(region2.growthFactorMag[0]));
	growthAuxData.growthFactorDirXAddress2 = thrust::raw_pointer_cast(
			&(region2.growthFactorDirXComp[0]));
	growthAuxData.growthFactorDirYAddress2 = thrust::raw_pointer_cast(
			&(region2.growthFactorDirYComp[0]));

	totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;
	//std::cout << "totalNodeCount = " << totalNodeCountForActiveCells
	//		<< std::endl;
	//std::cout << "before all functions start" << std::endl;
	copyGrowInfoFromGridToCells(region1, region2);
	//std::cout << "after copy grow info" << std::endl;
	updateGrowthProgress();
	//std::cout << "after update growth progress" << std::endl;
	decideIsScheduleToGrow();
	//std::cout << "after decode os schedule to grow" << std::endl;
	computeCellTargetLength();
	//std::cout << "after compute cell target length" << std::endl;
	computeDistToCellCenter();
	//std::cout << "after compute dist to center" << std::endl;
	findMinAndMaxDistToCenter();
	//std::cout << "after find min and max dist" << std::endl;
	computeLenDiffExpCur();
	//std::cout << "after compute diff " << std::endl;
	stretchCellGivenLenDiff();
	//std::cout << "after apply stretch force" << std::endl;
	cellChemotaxis();
	//std::cout << "after apply cell chemotaxis" << std::endl;
	addPointIfScheduledToGrow();
	//std::cout << "after adding node" << std::endl;
}

void SceCells::growAtRandom(double d_t) {
	totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;

	// randomly select growth direction and speed.
	randomizeGrowth();

	//std::cout << "after copy grow info" << std::endl;
	updateGrowthProgress();
	//std::cout << "after update growth progress" << std::endl;
	decideIsScheduleToGrow();
	//std::cout << "after decode os schedule to grow" << std::endl;
	computeCellTargetLength();
	//std::cout << "after compute cell target length" << std::endl;
	computeDistToCellCenter();
	//std::cout << "after compute dist to center" << std::endl;
	findMinAndMaxDistToCenter();
	//std::cout << "after find min and max dist" << std::endl;
	computeLenDiffExpCur();
	//std::cout << "after compute diff " << std::endl;
	stretchCellGivenLenDiff();
	//std::cout << "after apply stretch force" << std::endl;
	cellChemotaxis();
	//std::cout << "after apply cell chemotaxis" << std::endl;
	addPointIfScheduledToGrow();
	//std::cout << "after adding node" << std::endl;
}

/**
 * we need to copy the growth information from grid for chemical to cell nodes.
 */
void SceCells::copyGrowInfoFromGridToCells(GrowthDistriMap &region1,
		GrowthDistriMap &region2) {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.cellTypes.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.cellTypes.begin()))
					+ allocPara.currentActiveCellCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.growthSpeed.begin(),
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin())),
			LoadChemDataToNode(region1.gridDimensionX, region1.gridDimensionY,
					region1.gridSpacing, growthAuxData.growthFactorMagAddress,
					growthAuxData.growthFactorDirXAddress,
					growthAuxData.growthFactorDirYAddress,
					region2.gridDimensionX, region2.gridDimensionY,
					region2.gridSpacing, growthAuxData.growthFactorMagAddress2,
					growthAuxData.growthFactorDirXAddress2,
					growthAuxData.growthFactorDirYAddress2));
}

/**
 * Use the growth magnitude and dt to update growthProgress.
 */
void SceCells::updateGrowthProgress() {
	thrust::transform(cellInfoVecs.growthSpeed.begin(),
			cellInfoVecs.growthSpeed.begin() + allocPara.currentActiveCellCount,
			cellInfoVecs.growthProgress.begin(),
			cellInfoVecs.growthProgress.begin(), SaxpyFunctorWithMaxOfOne(dt));
}

/**
 * Decide if the cells are going to add a node or not.
 * Use lastCheckPoint and growthProgress to decide whether add point or not
 */
void SceCells::decideIsScheduleToGrow() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.lastCheckPoint.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.lastCheckPoint.begin()))
					+ allocPara.currentActiveCellCount,
			cellInfoVecs.isScheduledToGrow.begin(),
			PtCondiOp(miscPara.growThreshold));
}

/**
 * Calculate target length of cell given the cell growth progress.
 * length is along the growth direction.
 */
void SceCells::computeCellTargetLength() {
	thrust::transform(cellInfoVecs.growthProgress.begin(),
			cellInfoVecs.growthProgress.begin()
					+ allocPara.currentActiveCellCount,
			cellInfoVecs.expectedLength.begin(),
			CompuTarLen(bioPara.cellInitLength, bioPara.cellFinalLength));
}

/**
 * Compute distance of each node to its corresponding cell center.
 * The distantce could be either positive or negative, depending on the pre-defined
 * growth direction.
 */
void SceCells::computeDistToCellCenter() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_permutation_iterator(
									cellInfoVecs.centerCoordX.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.centerCoordY.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeIsActive.begin()
									+ allocPara.startPosCells)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_permutation_iterator(
									cellInfoVecs.centerCoordX.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.centerCoordY.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeIsActive.begin()
									+ allocPara.startPosCells))
					+ totalNodeCountForActiveCells,
			cellNodeInfoVecs.distToCenterAlongGrowDir.begin(), CompuDist());
}

/**
 * For nodes of each cell, find the maximum and minimum distance to the center.
 * We will then calculate the current length of a cell along its growth direction
 * using max and min distance to the center.
 */
void SceCells::findMinAndMaxDistToCenter() {
	thrust::reduce_by_key(
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara.maxNodeOfOneCell)),
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara.maxNodeOfOneCell))
					+ totalNodeCountForActiveCells,
			cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
			cellInfoVecs.cellRanksTmpStorage.begin(),
			cellInfoVecs.smallestDistance.begin(), thrust::equal_to<uint>(),
			thrust::minimum<double>());

	// for nodes of each cell, find the maximum distance from the node to the corresponding
	// cell center along the pre-defined growth direction.

	thrust::reduce_by_key(
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara.maxNodeOfOneCell)),
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara.maxNodeOfOneCell))
					+ totalNodeCountForActiveCells,
			cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
			cellInfoVecs.cellRanksTmpStorage.begin(),
			cellInfoVecs.biggestDistance.begin(), thrust::equal_to<uint>(),
			thrust::maximum<double>());

}

/**
 * Compute the difference for cells between their expected length and current length.
 */
void SceCells::computeLenDiffExpCur() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.smallestDistance.begin(),
							cellInfoVecs.biggestDistance.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.smallestDistance.begin(),
							cellInfoVecs.biggestDistance.begin()))
					+ allocPara.currentActiveCellCount,
			cellInfoVecs.lengthDifference.begin(), CompuDiff());
}

/**
 * Use the difference that just computed and growthXDir&growthYDir
 * to apply stretching force (velocity) on nodes of all cells
 */
void SceCells::stretchCellGivenLenDiff() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
							make_permutation_iterator(
									cellInfoVecs.lengthDifference.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara.startPosCells)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
							make_permutation_iterator(
									cellInfoVecs.lengthDifference.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara.startPosCells))
					+ totalNodeCountForActiveCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara.startPosCells)),
			ApplyStretchForce(bioPara.elongationCoefficient));
}
/**
 * This is just an attempt. Cells move according to chemicals.
 */
void SceCells::cellChemotaxis() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_permutation_iterator(
									cellInfoVecs.growthSpeed.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara.startPosCells)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_permutation_iterator(
									cellInfoVecs.growthSpeed.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara.maxNodeOfOneCell))),
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara.startPosCells))
					+ totalNodeCountForActiveCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara.startPosCells)),
			ApplyChemoVel(bioPara.chemoCoefficient));
}
/**
 * Adjust the velocities of nodes.
 * For example, velocity of boundary nodes must be zero.
 */
void SceCells::adjustNodeVel() {
	thrust::counting_iterator<uint> countingIterBegin(0);
	thrust::counting_iterator<uint> countingIterEnd(
			totalNodeCountForActiveCells + allocPara.startPosCells);

	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin(),
							nodes->getInfoVecs().nodeIsActive.begin(),
							nodes->getInfoVecs().nodeCellType.begin(),
							countingIterBegin)),
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin(),
							nodes->getInfoVecs().nodeIsActive.begin(),
							nodes->getInfoVecs().nodeCellType.begin(),
							countingIterBegin)) + totalNodeCountForActiveCells
					+ allocPara.startPosCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin())),
			VelocityModifier(allocPara.startPosProfile,
					allocPara.currentActiveProfileNodeCount));
}
/**
 * Move nodes according to the velocity we just adjusted.
 */
void SceCells::moveNodes() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin()))
					+ totalNodeCountForActiveCells + allocPara.startPosCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeLocX.begin(),
							nodes->getInfoVecs().nodeLocY.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeLocX.begin(),
							nodes->getInfoVecs().nodeLocY.begin())),
			SaxpyFunctorDim2(dt));
}
/**
 * Add a point to a cell if it is scheduled to grow.
 * This step does not guarantee success ; If adding new point failed, it will not change
 * isScheduleToGrow and activeNodeCount;
 */
void SceCells::addPointIfScheduledToGrow() {

	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isScheduledToGrow.begin(),
							cellInfoVecs.activeNodeCountOfThisCell.begin(),
							cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(), countingBegin,
							cellInfoVecs.lastCheckPoint.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isScheduledToGrow.begin(),
							cellInfoVecs.activeNodeCountOfThisCell.begin(),
							cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(), countingBegin,
							cellInfoVecs.lastCheckPoint.begin()))
					+ allocPara.currentActiveCellCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isScheduledToGrow.begin(),
							cellInfoVecs.activeNodeCountOfThisCell.begin(),
							cellInfoVecs.lastCheckPoint.begin())),
			AddPtOp(allocPara.maxNodeOfOneCell, miscPara.addNodeDistance,
					miscPara.minDistanceToOtherNode,
					growthAuxData.nodeIsActiveAddress,
					growthAuxData.nodeXPosAddress,
					growthAuxData.nodeYPosAddress, time(NULL),
					miscPara.growThreshold));
}

SceCells::SceCells(SceNodes* nodesInput,
		std::vector<uint>& numOfInitActiveNodesOfCells,
		std::vector<SceNodeType>& cellTypes) :
		countingBegin(0), initCellCount(
				nodesInput->getAllocPara().maxNodeOfOneCell / 2), initGrowthProgress(
				0.0) {
	initialize(nodesInput);

	copyInitActiveNodeCount(numOfInitActiveNodesOfCells);

	thrust::device_vector<SceNodeType> cellTypesToPass = cellTypes;
	setCellTypes(cellTypesToPass);

	distributeIsActiveInfo();
}

SceCells::SceCells(SceNodes* nodesInput,
		std::vector<uint>& initActiveMembrNodeCounts,
		std::vector<uint>& initActiveIntnlNodeCounts) {
	copyToGPUConstMem();
	initialize_M(nodesInput);
	copyInitActiveNodeCount_M(initActiveMembrNodeCounts,
			initActiveIntnlNodeCounts);
}

void SceCells::initCellInfoVecs() {
	cellInfoVecs.growthProgress.resize(allocPara.maxCellCount, 0.0);
	cellInfoVecs.expectedLength.resize(allocPara.maxCellCount,
			bioPara.cellInitLength);
	cellInfoVecs.lengthDifference.resize(allocPara.maxCellCount, 0.0);
	cellInfoVecs.smallestDistance.resize(allocPara.maxCellCount);
	cellInfoVecs.biggestDistance.resize(allocPara.maxCellCount);
	cellInfoVecs.activeNodeCountOfThisCell.resize(allocPara.maxCellCount);
	cellInfoVecs.lastCheckPoint.resize(allocPara.maxCellCount, 0.0);
	cellInfoVecs.isDivided.resize(allocPara.maxCellCount);
	cellInfoVecs.cellTypes.resize(allocPara.maxCellCount, MX);
	cellInfoVecs.isScheduledToGrow.resize(allocPara.maxCellCount, false);
	cellInfoVecs.centerCoordX.resize(allocPara.maxCellCount);
	cellInfoVecs.centerCoordY.resize(allocPara.maxCellCount);
	cellInfoVecs.centerCoordZ.resize(allocPara.maxCellCount);
	cellInfoVecs.cellRanksTmpStorage.resize(allocPara.maxCellCount);
	cellInfoVecs.growthSpeed.resize(allocPara.maxCellCount, 0.0);
	cellInfoVecs.growthXDir.resize(allocPara.maxCellCount);
	cellInfoVecs.growthYDir.resize(allocPara.maxCellCount);
	cellInfoVecs.isRandGrowInited.resize(allocPara.maxCellCount, false);
}

void SceCells::initCellInfoVecs_M() {
	std::cout << "max cell count = " << allocPara_m.maxCellCount << std::endl;
	cellInfoVecs.growthProgress.resize(allocPara_m.maxCellCount, 0.0);
	cellInfoVecs.expectedLength.resize(allocPara_m.maxCellCount,
			bioPara.cellInitLength);
	cellInfoVecs.lengthDifference.resize(allocPara_m.maxCellCount, 0.0);
	cellInfoVecs.smallestDistance.resize(allocPara_m.maxCellCount);
	cellInfoVecs.biggestDistance.resize(allocPara_m.maxCellCount);
	cellInfoVecs.activeMembrNodeCounts.resize(allocPara_m.maxCellCount);
	cellInfoVecs.activeIntnlNodeCounts.resize(allocPara_m.maxCellCount);
	cellInfoVecs.lastCheckPoint.resize(allocPara_m.maxCellCount, 0.0);
	cellInfoVecs.isDivided.resize(allocPara_m.maxCellCount);
	cellInfoVecs.isScheduledToGrow.resize(allocPara_m.maxCellCount, false);
	cellInfoVecs.centerCoordX.resize(allocPara_m.maxCellCount);
	cellInfoVecs.centerCoordY.resize(allocPara_m.maxCellCount);
	cellInfoVecs.cellRanksTmpStorage.resize(allocPara_m.maxCellCount);
	cellInfoVecs.growthSpeed.resize(allocPara_m.maxCellCount, 0.0);
	cellInfoVecs.growthXDir.resize(allocPara_m.maxCellCount);
	cellInfoVecs.growthYDir.resize(allocPara_m.maxCellCount);
	cellInfoVecs.isRandGrowInited.resize(allocPara_m.maxCellCount, false);
	std::cout << "finished " << std::endl;
}

void SceCells::initCellNodeInfoVecs() {
	cellNodeInfoVecs.cellRanks.resize(allocPara.maxTotalCellNodeCount);
	cellNodeInfoVecs.activeXPoss.resize(allocPara.maxTotalCellNodeCount);
	cellNodeInfoVecs.activeYPoss.resize(allocPara.maxTotalCellNodeCount);
	cellNodeInfoVecs.activeZPoss.resize(allocPara.maxTotalCellNodeCount);
	cellNodeInfoVecs.distToCenterAlongGrowDir.resize(
			allocPara.maxTotalCellNodeCount);
}

void SceCells::initCellNodeInfoVecs_M() {
	std::cout << "max total node count = " << allocPara_m.maxTotalNodeCount
			<< std::endl;
	cellNodeInfoVecs.cellRanks.resize(allocPara_m.maxTotalNodeCount);
	cellNodeInfoVecs.activeXPoss.resize(allocPara_m.maxTotalNodeCount);
	cellNodeInfoVecs.activeYPoss.resize(allocPara_m.maxTotalNodeCount);
	cellNodeInfoVecs.activeZPoss.resize(allocPara_m.maxTotalNodeCount);
	cellNodeInfoVecs.distToCenterAlongGrowDir.resize(
			allocPara_m.maxTotalNodeCount);
}

void SceCells::initGrowthAuxData() {
	growthAuxData.nodeIsActiveAddress = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeIsActive[allocPara.startPosCells]));
	growthAuxData.nodeXPosAddress = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeLocX[allocPara.startPosCells]));
	growthAuxData.nodeYPosAddress = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeLocY[allocPara.startPosCells]));
	growthAuxData.randomGrowthSpeedMin = globalConfigVars.getConfigValue(
			"RandomGrowthSpeedMin").toDouble();
	growthAuxData.randomGrowthSpeedMax = globalConfigVars.getConfigValue(
			"RandomGrowthSpeedMax").toDouble();
	growthAuxData.randGenAuxPara = globalConfigVars.getConfigValue(
			"RandomGenerationAuxPara").toDouble();

	if (controlPara.simuType == SingleCellTest) {
		growthAuxData.fixedGrowthSpeed = globalConfigVars.getConfigValue(
				"FixedGrowthSpeed").toDouble();
	}
}

void SceCells::initGrowthAuxData_M() {
	growthAuxData.nodeIsActiveAddress = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeIsActive[allocPara_m.bdryNodeCount]));
	growthAuxData.nodeXPosAddress = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeLocX[allocPara_m.bdryNodeCount]));
	growthAuxData.nodeYPosAddress = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeLocY[allocPara_m.bdryNodeCount]));
	growthAuxData.randomGrowthSpeedMin = globalConfigVars.getConfigValue(
			"RandomGrowthSpeedMin").toDouble();
	growthAuxData.randomGrowthSpeedMax = globalConfigVars.getConfigValue(
			"RandomGrowthSpeedMax").toDouble();
	growthAuxData.randGenAuxPara = globalConfigVars.getConfigValue(
			"RandomGenerationAuxPara").toDouble();
}

void SceCells::initialize(SceNodes* nodesInput) {
	nodes = nodesInput;
	controlPara = nodes->getControlPara();
	readMiscPara();
	readBioPara();

	allocPara = nodesInput->getAllocPara();

	initCellInfoVecs();
	initCellNodeInfoVecs();
	initGrowthAuxData();

	distributeIsCellRank();
}

void SceCells::initialize_M(SceNodes* nodesInput) {
	std::cout << "break point 0 " << std::endl;
	std::cout.flush();
	nodes = nodesInput;
	allocPara_m = nodesInput->getAllocParaM();
	std::cout << "break point 1 " << std::endl;
	std::cout.flush();
	controlPara = nodes->getControlPara();
	std::cout << "break point 2 " << std::endl;
	std::cout.flush();
	readMiscPara_M();
	std::cout << "break point 3 " << std::endl;
	std::cout.flush();
	initCellInfoVecs_M();

	std::cout << "break point 4 " << std::endl;
	std::cout.flush();
	readBioPara();
	std::cout << "break point 5 " << std::endl;
	std::cout.flush();

	std::cout << "break point 6 " << std::endl;
	std::cout.flush();
	initCellNodeInfoVecs_M();
	std::cout << "break point 7 " << std::endl;
	std::cout.flush();
	initGrowthAuxData_M();
	std::cout << "break point 8 " << std::endl;
	std::cout.flush();

}

void SceCells::copyInitActiveNodeCount(
		std::vector<uint>& numOfInitActiveNodesOfCells) {
	thrust::copy(numOfInitActiveNodesOfCells.begin(),
			numOfInitActiveNodesOfCells.end(),
			cellInfoVecs.activeNodeCountOfThisCell.begin());
}

void SceCells::allComponentsMove() {
	adjustNodeVel();
	moveNodes();
}

/**
 * Mark cell node as either activdistributeIsActiveInfo()e or inactive.
 * left part of the node array will be active and right part will be inactive.
 * the threshold is defined by array activeNodeCountOfThisCell.
 * e.g. activeNodeCountOfThisCell = {2,3} and  maxNodeOfOneCell = 5
 */
void SceCells::distributeIsActiveInfo() {
//std::cout << "before distribute bdry isActive" << std::endl;
	distributeBdryIsActiveInfo();
//std::cout << "before distribute profile isActive" << std::endl;
	distributeProfileIsActiveInfo();
//std::cout << "before distribute ecm isActive" << std::endl;
	distributeECMIsActiveInfo();
//std::cout << "before distribute cells isActive" << std::endl;
	distributeCellIsActiveInfo();
}

void SceCells::distributeIsCellRank() {
	uint totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::counting_iterator<uint> countingCellEnd(
			totalNodeCountForActiveCells);
	std::cerr << "totalNodeCount for active cells "
			<< totalNodeCountForActiveCells << std::endl;

//thrust::counting_iterator<uint> countingECMEnd(countingECMEnd);

// only computes the cell ranks of cells. the rest remain unchanged.
	thrust::transform(countingBegin, countingCellEnd,
			nodes->getInfoVecs().nodeCellRank.begin() + allocPara.startPosCells,
			DivideFunctor(allocPara.maxNodeOfOneCell));
	std::cerr << "finished cellRank transformation" << std::endl;
}

/**
 * This method computes center of all cells.
 * more efficient then simply iterating the cell because of parallel reducing.
 */
void SceCells::computeCenterPos() {
	uint totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::counting_iterator<uint> countingEnd(totalNodeCountForActiveCells);
	uint totalNumberOfActiveNodes = thrust::reduce(
			cellInfoVecs.activeNodeCountOfThisCell.begin(),
			cellInfoVecs.activeNodeCountOfThisCell.begin()
					+ allocPara.currentActiveCellCount);

	thrust::copy_if(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_transform_iterator(countingBegin,
									DivideFunctor(allocPara.maxNodeOfOneCell)),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocZ.begin()
									+ allocPara.startPosCells)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_transform_iterator(countingBegin,
									DivideFunctor(allocPara.maxNodeOfOneCell)),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocZ.begin()
									+ allocPara.startPosCells))
					+ totalNodeCountForActiveCells,
			nodes->getInfoVecs().nodeIsActive.begin() + allocPara.startPosCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellNodeInfoVecs.cellRanks.begin(),
							cellNodeInfoVecs.activeXPoss.begin(),
							cellNodeInfoVecs.activeYPoss.begin(),
							cellNodeInfoVecs.activeZPoss.begin())), isTrue());

	thrust::reduce_by_key(cellNodeInfoVecs.cellRanks.begin(),
			cellNodeInfoVecs.cellRanks.begin() + totalNumberOfActiveNodes,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellNodeInfoVecs.activeXPoss.begin(),
							cellNodeInfoVecs.activeYPoss.begin(),
							cellNodeInfoVecs.activeZPoss.begin())),
			cellInfoVecs.cellRanksTmpStorage.begin(),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin())),
			thrust::equal_to<uint>(), CVec3Add());
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin()))
					+ allocPara.currentActiveCellCount,
			cellInfoVecs.activeNodeCountOfThisCell.begin(),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin())), CVec3Divide());
}

/**
 * 2D version of cell division.
 * Division process is done by creating two temporary vectors to hold the node information
 * that are going to divide.
 *
 * step 1: based on lengthDifference, expectedLength and growthProgress,
 *     this process determines whether a certain cell is ready to divide and then assign
 *     a boolean value to isDivided.
 *
 * step 2. copy those cells that will divide in to the temp vectors created
 *
 * step 3. For each cell in the temp vectors, we sort its nodes by its distance to the
 * corresponding cell center.
 * This step is not very effcient when the number of cells going to divide is big.
 * but this is unlikely to happen because cells will divide according to external chemical signaling
 * and each will have different divide progress.
 *
 * step 4. copy the right part of each cell of the sorted array (temp1) to left part of each cell of
 * another array
 *
 * step 5. transform isActive vector of both temp1 and temp2, making only left part of each cell active.
 *
 * step 6. insert temp2 to the end of the cell array
 *
 * step 7. copy temp1 to the previous position of the cell array.
 *
 * step 8. add activeCellCount of the system.
 *
 * step 9. mark isDivide of all cells to false.
 */

void SceCells::divide2DSimplified() {
	bool isDivisionPresent = decideIfGoingToDivide();
	if (!isDivisionPresent) {
		return;
	}
	copyCellsPreDivision();
	sortNodesAccordingToDist();
	copyLeftAndRightToSeperateArrays();
	transformIsActiveArrayOfBothArrays();
	addSecondArrayToCellArray();
	copyFirstArrayToPreviousPos();
	updateActiveCellCount();
	markIsDivideFalse();
}

bool SceCells::decideIfGoingToDivide() {
// step 1
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.lengthDifference.begin(),
							cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.activeNodeCountOfThisCell.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.lengthDifference.begin(),
							cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.activeNodeCountOfThisCell.begin()))
					+ allocPara.currentActiveCellCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isDivided.begin(),
							cellInfoVecs.growthProgress.begin())),
			CompuIsDivide(miscPara.isDivideCriticalRatio,
					allocPara.maxNodeOfOneCell));
// sum all bool values which indicate whether the cell is going to divide.
// toBeDivideCount is the total number of cells going to divide.
	divAuxData.toBeDivideCount = thrust::reduce(cellInfoVecs.isDivided.begin(),
			cellInfoVecs.isDivided.begin() + allocPara.currentActiveCellCount,
			(uint) (0));
	if (divAuxData.toBeDivideCount > 0) {
		return true;
	} else {
		return false;
	}
}

void SceCells::copyCellsPreDivision() {
// step 2 : copy all cell rank and distance to its corresponding center with divide flag = 1
	totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;

	divAuxData.nodeStorageCount = divAuxData.toBeDivideCount
			* allocPara.maxNodeOfOneCell;
	divAuxData.tmpIsActiveHold1 = thrust::device_vector<bool>(
			divAuxData.nodeStorageCount, true);
	divAuxData.tmpDistToCenter1 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpCellRankHold1 = thrust::device_vector<uint>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpXValueHold1 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpYValueHold1 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpZValueHold1 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);

	divAuxData.tmpCellTypes = thrust::device_vector<SceNodeType>(
			divAuxData.nodeStorageCount);

	divAuxData.tmpIsActiveHold2 = thrust::device_vector<bool>(
			divAuxData.nodeStorageCount, false);
	divAuxData.tmpDistToCenter2 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpXValueHold2 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpYValueHold2 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpZValueHold2 = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);

// step 2 , continued
	thrust::copy_if(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_transform_iterator(countingBegin,
									DivideFunctor(allocPara.maxNodeOfOneCell)),
							cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocZ.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeCellType.begin()
									+ allocPara.startPosCells)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_transform_iterator(countingBegin,
									DivideFunctor(allocPara.maxNodeOfOneCell)),
							cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocZ.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeCellType.begin()
									+ allocPara.startPosCells))
					+ totalNodeCountForActiveCells,
			thrust::make_permutation_iterator(cellInfoVecs.isDivided.begin(),
					make_transform_iterator(countingBegin,
							DivideFunctor(allocPara.maxNodeOfOneCell))),
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpCellRankHold1.begin(),
							divAuxData.tmpDistToCenter1.begin(),
							divAuxData.tmpXValueHold1.begin(),
							divAuxData.tmpYValueHold1.begin(),
							divAuxData.tmpZValueHold1.begin(),
							divAuxData.tmpCellTypes.begin())), isTrue());
}

/**
 * performance wise, this implementation is not the best because I can use only one sort_by_key
 * with speciialized comparision operator. However, This implementation is more robust and won't
 * compromise performance too much.
 */
void SceCells::sortNodesAccordingToDist() {
//step 3
	for (uint i = 0; i < divAuxData.toBeDivideCount; i++) {
		thrust::sort_by_key(
				divAuxData.tmpDistToCenter1.begin()
						+ i * allocPara.maxNodeOfOneCell,
				divAuxData.tmpDistToCenter1.begin()
						+ (i + 1) * allocPara.maxNodeOfOneCell,
				thrust::make_zip_iterator(
						thrust::make_tuple(
								divAuxData.tmpXValueHold1.begin()
										+ i * allocPara.maxNodeOfOneCell,
								divAuxData.tmpYValueHold1.begin()
										+ i * allocPara.maxNodeOfOneCell,
								divAuxData.tmpZValueHold1.begin()
										+ i * allocPara.maxNodeOfOneCell)));
	}
}

/**
 * scatter_if() is a thrust function.
 * inputIter1 first,
 * inputIter1 last,
 * inputIter2 map,
 * inputIter3 stencil
 * randomAccessIter output
 */
void SceCells::copyLeftAndRightToSeperateArrays() {
//step 4.
	thrust::scatter_if(
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpXValueHold1.begin(),
							divAuxData.tmpYValueHold1.begin(),
							divAuxData.tmpZValueHold1.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpXValueHold1.end(),
							divAuxData.tmpYValueHold1.end(),
							divAuxData.tmpZValueHold1.end())),
			make_transform_iterator(countingBegin,
					LeftShiftFunctor(allocPara.maxNodeOfOneCell)),
			make_transform_iterator(countingBegin,
					IsRightSide(allocPara.maxNodeOfOneCell)),
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpXValueHold2.begin(),
							divAuxData.tmpYValueHold2.begin(),
							divAuxData.tmpZValueHold2.begin())));
}

void SceCells::transformIsActiveArrayOfBothArrays() {
	thrust::transform(countingBegin,
			countingBegin + divAuxData.nodeStorageCount,
			divAuxData.tmpIsActiveHold1.begin(),
			IsLeftSide(allocPara.maxNodeOfOneCell));
	thrust::transform(countingBegin,
			countingBegin + divAuxData.nodeStorageCount,
			divAuxData.tmpIsActiveHold2.begin(),
			IsLeftSide(allocPara.maxNodeOfOneCell));
	if (divAuxData.toBeDivideCount != 0) {
		std::cout << "before insert, active cell count in nodes:"
				<< nodes->getAllocPara().currentActiveCellCount << std::endl;
	}
}

void SceCells::addSecondArrayToCellArray() {
/// step 6. call SceNodes function to add newly divided cells
	nodes->addNewlyDividedCells(divAuxData.tmpXValueHold2,
			divAuxData.tmpYValueHold2, divAuxData.tmpZValueHold2,
			divAuxData.tmpIsActiveHold2, divAuxData.tmpCellTypes);
}

void SceCells::copyFirstArrayToPreviousPos() {
	thrust::scatter(
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpIsActiveHold1.begin(),
							divAuxData.tmpXValueHold1.begin(),
							divAuxData.tmpYValueHold1.begin(),
							divAuxData.tmpZValueHold1.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpIsActiveHold1.end(),
							divAuxData.tmpXValueHold1.end(),
							divAuxData.tmpYValueHold1.end(),
							divAuxData.tmpZValueHold1.end())),
			thrust::make_transform_iterator(
					thrust::make_zip_iterator(
							thrust::make_tuple(countingBegin,
									divAuxData.tmpCellRankHold1.begin())),
					CompuPos(allocPara.maxNodeOfOneCell)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							nodes->getInfoVecs().nodeIsActive.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara.startPosCells,
							nodes->getInfoVecs().nodeLocZ.begin()
									+ allocPara.startPosCells)));

	/**
	 * after dividing, the cell should resume the initial
	 * (1) node count, which defaults to be half size of max node count
	 * (2) growth progress, which defaults to 0
	 * (3) last check point, which defaults to 0
	 */
	thrust::scatter_if(
			thrust::make_zip_iterator(
					thrust::make_tuple(initCellCount, initGrowthProgress,
							initGrowthProgress)),
			thrust::make_zip_iterator(
					thrust::make_tuple(initCellCount, initGrowthProgress,
							initGrowthProgress))
					+ allocPara.currentActiveCellCount, countingBegin,
			cellInfoVecs.isDivided.begin(),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							cellInfoVecs.activeNodeCountOfThisCell.begin(),
							cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.lastCheckPoint.begin())), isTrue());

// TODO: combine this one with the previous scatter_if to improve efficiency.
	thrust::fill(
			cellInfoVecs.activeNodeCountOfThisCell.begin()
					+ allocPara.currentActiveCellCount,
			cellInfoVecs.activeNodeCountOfThisCell.begin()
					+ allocPara.currentActiveCellCount
					+ divAuxData.toBeDivideCount,
			allocPara.maxNodeOfOneCell / 2);

}

void SceCells::updateActiveCellCount() {
	allocPara.currentActiveCellCount = allocPara.currentActiveCellCount
			+ divAuxData.toBeDivideCount;
	NodeAllocPara para = nodes->getAllocPara();
	para.currentActiveCellCount = allocPara.currentActiveCellCount;
	nodes->setAllocPara(para);
}

void SceCells::markIsDivideFalse() {
	thrust::fill(cellInfoVecs.isDivided.begin(),
			cellInfoVecs.isDivided.begin() + allocPara.currentActiveCellCount,
			false);
}

void SceCells::readMiscPara() {
	miscPara.addNodeDistance = globalConfigVars.getConfigValue(
			"DistanceForAddingNode").toDouble();
	miscPara.minDistanceToOtherNode = globalConfigVars.getConfigValue(
			"MinDistanceToOtherNode").toDouble();
	miscPara.isDivideCriticalRatio = globalConfigVars.getConfigValue(
			"IsDivideCrticalRatio").toDouble();
// reason for adding a small term here is to avoid scenario when checkpoint might add many times
// up to 0.99999999 which is theoretically 1.0 but not in computer memory. If we don't include
// this small term we might risk adding one more node.
	int maxNodeOfOneCell =
			globalConfigVars.getConfigValue("MaxNodePerCell").toInt();
	miscPara.growThreshold = 1.0 / (maxNodeOfOneCell - maxNodeOfOneCell / 2)
			+ epsilon;
}

void SceCells::readMiscPara_M() {
	miscPara.addNodeDistance = globalConfigVars.getConfigValue(
			"DistanceForAddingNode").toDouble();
	miscPara.minDistanceToOtherNode = globalConfigVars.getConfigValue(
			"MinDistanceToOtherNode").toDouble();
	miscPara.isDivideCriticalRatio = globalConfigVars.getConfigValue(
			"IsDivideCrticalRatio").toDouble();
// reason for adding a small term here is to avoid scenario when checkpoint might add many times
// up to 0.99999999 which is theoretically 1.0 but not in computer memory. If we don't include
// this small term we might risk adding one more node.
	int maxNodeOfOneCell = globalConfigVars.getConfigValue(
			"MaxIntnlNodeCountPerCell").toInt();
	miscPara.growThreshold = 1.0 / (maxNodeOfOneCell - maxNodeOfOneCell / 2)
			+ epsilon;
}

void SceCells::readBioPara() {
	bioPara.cellInitLength =
			globalConfigVars.getConfigValue("CellInitLength").toDouble();
	std::cout << "break point 1 " << bioPara.cellInitLength << std::endl;
	std::cout.flush();
	bioPara.cellFinalLength =
			globalConfigVars.getConfigValue("CellFinalLength").toDouble();
	std::cout << "break point 2 " << bioPara.cellFinalLength << std::endl;
	std::cout.flush();
	bioPara.elongationCoefficient = globalConfigVars.getConfigValue(
			"ElongateCoefficient").toDouble();
	std::cout << "break point 3 " << bioPara.elongationCoefficient << std::endl;
	std::cout.flush();
	if (controlPara.simuType == Beak) {
		std::cout << "break point 4 " << std::endl;
		std::cout.flush();
		bioPara.chemoCoefficient = globalConfigVars.getConfigValue(
				"ChemoCoefficient").toDouble();
	}
}

void SceCells::randomizeGrowth() {
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.isRandGrowInited.begin(),
							countingBegin)),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.isRandGrowInited.begin(),
							countingBegin)) + allocPara.currentActiveCellCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.growthSpeed.begin(),
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.isRandGrowInited.begin())),
			AssignRandIfNotInit(growthAuxData.randomGrowthSpeedMin,
					growthAuxData.randomGrowthSpeedMax,
					allocPara.currentActiveCellCount,
					growthAuxData.randGenAuxPara));
}

/**
 * To run all the cell level logics.
 * First step we got center positions of cells.
 * Grow.
 */
void SceCells::runAllCellLevelLogicsDisc(double dt) {
	this->dt = dt;
//std::cerr << "enter run all cell level logics" << std::endl;
	computeCenterPos();
//std::cerr << "after compute center position." << std::endl;

	if (nodes->getControlPara().controlSwitchs.stab == OFF) {
		growAtRandom(dt);
		//grow2DTwoRegions(dt, region1, region2);
		//std::cerr << "after grow cells" << std::endl;
		//distributeIsActiveInfo();
		//std::cerr << "after distribute is active info." << std::endl;
		divide2DSimplified();
		//std::cerr << "after divide 2D simplified." << std::endl;
		distributeIsActiveInfo();
		//std::cerr << "after distribute is active info." << std::endl;
		distributeCellGrowthProgress();
	}

	allComponentsMove();
//std::cerr << "after all components move." << std::endl;
}

void SceCells::runAllCellLogicsDisc_M(double dt) {
	this->dt = dt;

	applyMemTension_M();

	//computeCenterPos_M();

//growAtRandom_M(dt);

//divide2D_M();

	//distributeCellGrowthProgress_M();

	allComponentsMove_M();
}

void SceCells::runStretchTest(double dt) {
	this->dt = dt;
	computeCenterPos();
	growAlongX(false, dt);
	moveNodes();
}

void SceCells::runAllCellLevelLogicsBeak(double dt, GrowthDistriMap& region1,
		GrowthDistriMap& region2) {
	this->dt = dt;
//std::cerr << "enter run all cell level logics" << std::endl;
	computeCenterPos();
//std::cerr << "after compute center position." << std::endl;
// for wind disk project, switch from chemical based growth to random growth
//growAtRandom(dt);

	if (nodes->getControlPara().controlSwitchs.stab == OFF) {
		grow2DTwoRegions(dt, region1, region2);
		//std::cerr << "after grow cells" << std::endl;
		distributeIsActiveInfo();
		//std::cerr << "after distribute is active info." << std::endl;
		divide2DSimplified();
		//std::cerr << "after divide 2D simplified." << std::endl;
		distributeIsActiveInfo();
		//std::cerr << "after distribute is active info." << std::endl;
	}

	allComponentsMove();
//std::cerr << "after all components move." << std::endl;
}

void SceCells::growAlongX(bool isAddPt, double d_t) {
	totalNodeCountForActiveCells = allocPara.currentActiveCellCount
			* allocPara.maxNodeOfOneCell;

	setGrowthDirXAxis();

//std::cout << "after copy grow info" << std::endl;
	updateGrowthProgress();
//std::cout << "after update growth progress" << std::endl;
	decideIsScheduleToGrow();
//std::cout << "after decode os schedule to grow" << std::endl;
	computeCellTargetLength();
//std::cout << "after compute cell target length" << std::endl;
	computeDistToCellCenter();
//std::cout << "after compute dist to center" << std::endl;
	findMinAndMaxDistToCenter();
//std::cout << "after find min and max dist" << std::endl;
	computeLenDiffExpCur();
//std::cout << "after compute diff " << std::endl;
	stretchCellGivenLenDiff();

	if (isAddPt) {
		addPointIfScheduledToGrow();
	}
}

void SceCells::growWithStress(double d_t) {
}

std::vector<CVector> SceCells::getAllCellCenters() {
	thrust::host_vector<double> centerX = cellInfoVecs.centerCoordX;
	thrust::host_vector<double> centerY = cellInfoVecs.centerCoordY;
	thrust::host_vector<double> centerZ = cellInfoVecs.centerCoordZ;
	std::vector<CVector> result;
	for (uint i = 0; i < allocPara.currentActiveCellCount; i++) {
		CVector pos = CVector(centerX[i], centerY[i], centerZ[i]);
		result.push_back(pos);
	}
	return result;
}

void SceCells::setGrowthDirXAxis() {
	thrust::fill(cellInfoVecs.growthXDir.begin(),
			cellInfoVecs.growthXDir.begin() + allocPara.currentActiveCellCount,
			1.0);
	thrust::fill(cellInfoVecs.growthYDir.begin(),
			cellInfoVecs.growthYDir.begin() + allocPara.currentActiveCellCount,
			0.0);
	thrust::fill(cellInfoVecs.growthSpeed.begin(),
			cellInfoVecs.growthSpeed.begin() + allocPara.currentActiveCellCount,
			growthAuxData.fixedGrowthSpeed);
}

std::vector<double> SceCells::getGrowthProgressVec() {
	thrust::host_vector<double> growthProVec = cellInfoVecs.growthProgress;
	std::vector<double> result;
	for (uint i = 0; i < allocPara.currentActiveCellCount; i++) {
		result.push_back(growthProVec[i]);
	}
	return result;
}

void SceCells::copyCellsPreDivision_M() {
	totalNodeCountForActiveCells = allocPara_m.currentActiveCellCount
			* allocPara_m.maxAllNodePerCell;

	divAuxData.nodeStorageCount = divAuxData.toBeDivideCount
			* allocPara_m.maxAllNodePerCell;

	divAuxData.tmpIsActive_M = thrust::device_vector<bool>(
			divAuxData.nodeStorageCount, true);
	divAuxData.tmpNodePosX_M = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpNodePosY_M = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);

	divAuxData.tmpCellRank_M = thrust::device_vector<uint>(
			divAuxData.toBeDivideCount, 0);
	divAuxData.tmpDivDirX_M = thrust::device_vector<double>(
			divAuxData.toBeDivideCount, 0);
	divAuxData.tmpDivDirY_M = thrust::device_vector<double>(
			divAuxData.toBeDivideCount, 0);
	divAuxData.tmpCenterPosX_M = thrust::device_vector<double>(
			divAuxData.toBeDivideCount, 0);
	divAuxData.tmpCenterPosY_M = thrust::device_vector<double>(
			divAuxData.toBeDivideCount, 0);

	divAuxData.tmpIsActive1_M = thrust::device_vector<bool>(
			divAuxData.nodeStorageCount, false);
	divAuxData.tmpXPos1_M = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpYPos1_M = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);

	divAuxData.tmpIsActive2_M = thrust::device_vector<bool>(
			divAuxData.nodeStorageCount, false);
	divAuxData.tmpXPos2_M = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);
	divAuxData.tmpYPos2_M = thrust::device_vector<double>(
			divAuxData.nodeStorageCount, 0.0);

// step 2 , continued
	thrust::copy_if(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							nodes->getInfoVecs().nodeIsActive.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							nodes->getInfoVecs().nodeIsActive.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount))
					+ totalNodeCountForActiveCells,
			thrust::make_permutation_iterator(cellInfoVecs.isDivided.begin(),
					make_transform_iterator(countingBegin,
							DivideFunctor(allocPara_m.maxAllNodePerCell))),
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpIsActive_M.begin(),
							divAuxData.tmpNodePosX_M.begin(),
							divAuxData.tmpNodePosY_M.begin())), isTrue());
// step 2 , continued
	thrust::copy_if(
			thrust::make_zip_iterator(
					thrust::make_tuple(countingBegin,
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(countingBegin,
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin()))
					+ divAuxData.toBeDivideCount,
			cellInfoVecs.isDivided.begin(),
			thrust::make_zip_iterator(
					thrust::make_tuple(divAuxData.tmpCellRank_M.begin(),
							divAuxData.tmpDivDirX_M.begin(),
							divAuxData.tmpDivDirY_M.begin(),
							divAuxData.tmpCenterPosX_M.begin(),
							divAuxData.tmpCenterPosY_M.begin())), isTrue());
}

void SceCells::createTwoNewCellArr_M() {
	divAuxData.tmp1MemActiveCounts.clear();
	divAuxData.tmp1InternalActiveCounts.clear();
	divAuxData.tmp2MemActiveCounts.clear();
	divAuxData.tmp2InternalActiveCounts.clear();

	uint membThreshold = allocPara_m.maxMembrNodePerCell;
	uint maxAllNodePerCell = allocPara_m.maxAllNodePerCell;
	uint index;

	for (uint i = 0; i < divAuxData.toBeDivideCount; i++) {
		divAuxData.tmp1Vec.clear();
		divAuxData.tmp2Vec.clear();
		divAuxData.tmp1VecMem.clear();
		divAuxData.tmp2VecMem.clear();
		uint cellRank = divAuxData.tmpCellRank_M[i];
		double curLen = cellInfoVecs.biggestDistance[cellRank]
				- cellInfoVecs.smallestDistance[cellRank];
		double oldCenterX = divAuxData.tmpCenterPosX_M[i];
		double oldCenterY = divAuxData.tmpCenterPosY_M[i];
		CVector centerPos(oldCenterX, oldCenterY, 0);
		double divDirX = divAuxData.tmpDivDirX_M[i];
		double divDirY = divAuxData.tmpDivDirY_M[i];
		CVector divDir(divDirX, divDirY, 0);
		double tmpSqrt = sqrt(divDirX * divDirX + divDirY * divDirY);
		double lenChange = curLen / 2.0 * centerShiftRatio;
		double cell1CenterX = oldCenterX + divDirX / tmpSqrt * lenChange;
		double cell1CenterY = oldCenterY + divDirY / tmpSqrt * lenChange;
		double cell2CenterX = oldCenterX - divDirX / tmpSqrt * lenChange;
		double cell2CenterY = oldCenterY - divDirY / tmpSqrt * lenChange;
		CVector cell1Center(cell1CenterX, cell1CenterY, 0);
		CVector cell2Center(cell2CenterX, cell2CenterY, 0);

		double curMin1Val = 1.0e4, curMin2Val = 1.0e4;
		uint curMin1Indx, curMin2Indx;

		uint activeMemThreshold = cellInfoVecs.activeMembrNodeCounts[cellRank];

		for (uint j = 0; j < maxAllNodePerCell; j++) {
			index = i * maxAllNodePerCell + j + membThreshold;
			if (j < membThreshold) {
				// means node type is membrane
				if (divAuxData.tmpIsActive1_M[index] == true) {
					CVector memPos(divAuxData.tmpNodePosX_M[index],
							divAuxData.tmpNodePosX_M[index], 0);
					CVector centerToPosDir = memPos - centerPos;
					CVector crossProduct = Cross(centerToPosDir, divDir);
					double dotProduct = centerToPosDir * divDir;
					if (crossProduct.z >= 0) {
						// less than pi, clock-wise
						if (fabs(dotProduct) < curMin1Val) {
							curMin1Val = fabs(dotProduct);
							curMin1Indx = j;
						}
					} else {
						// more than pi, clock-wise
						if (fabs(dotProduct) < curMin2Val) {
							curMin2Val = fabs(dotProduct);
							curMin2Indx = j;
						}
					}
				}
			} else {
				if (divAuxData.tmpIsActive1_M[index] == true) {
					CVector internalPos(divAuxData.tmpNodePosX_M[index],
							divAuxData.tmpNodePosX_M[index], 0);
					CVector centerToPosDir = internalPos - centerPos;
					CVector shrinkedPos = centerToPosDir * shrinkRatio
							+ centerPos;
					double dotProduct = centerToPosDir * divDir;
					if (dotProduct > 0) {
						divAuxData.tmp1Vec.push_back(shrinkedPos);
					} else {
						divAuxData.tmp2Vec.push_back(shrinkedPos);
					}
				}
			}
		}

		////////////////////////////////
		//// copy membrane nodes ///////
		////////////////////////////////

		CVector memOne(divAuxData.tmpNodePosX_M[curMin1Indx],
				divAuxData.tmpNodePosY_M[curMin1Indx], 0);
		CVector memTwo(divAuxData.tmpNodePosX_M[curMin2Indx],
				divAuxData.tmpNodePosY_M[curMin2Indx], 0);

		uint oneToTwoCounter = 0, twoToOneCounter = 0;
		uint nextIndx = curMin1Indx;
		while (nextIndx != curMin2Indx) {
			CVector memPos(divAuxData.tmpNodePosX_M[nextIndx],
					divAuxData.tmpNodePosY_M[nextIndx], 0);
			divAuxData.tmp1VecMem.push_back(memPos);
			oneToTwoCounter++;
			nextIndx = nextIndx + 1;
			if (nextIndx == activeMemThreshold) {
				nextIndx = 0;
			}
		}
		CVector twoToOne = memOne - memTwo;
		CVector twoToOneUnit = twoToOne.getUnitVector();
		double edgeLength = twoToOne.getModul();
		uint numNewMemNodes = edgeLength / memNewSpacing;
		CVector nodeOld = memTwo, nodeNew;
		for (uint j = 0; j < numNewMemNodes; j++) {
			divAuxData.tmp1VecMem.push_back(nodeOld);
			nodeNew = nodeOld + memNewSpacing * twoToOneUnit;
			nodeOld = nodeNew;
		}
		divAuxData.tmp1MemActiveCounts.push_back(divAuxData.tmp1VecMem.size());
		for (uint j = 0; j < membThreshold; j++) {
			index = i * maxAllNodePerCell + j;
			if (j < divAuxData.tmp1VecMem.size()) {
				divAuxData.tmpXPos1_M[index] = divAuxData.tmp1VecMem[j].x;
				divAuxData.tmpYPos1_M[index] = divAuxData.tmp1VecMem[j].y;
				divAuxData.tmpIsActive1_M[index] = true;
			} else {
				divAuxData.tmpIsActive1_M[index] = false;
			}
		}

		nextIndx = curMin2Indx;
		while (nextIndx != curMin1Indx) {
			CVector memPos(divAuxData.tmpNodePosX_M[nextIndx],
					divAuxData.tmpNodePosY_M[nextIndx], 0);
			divAuxData.tmp2VecMem.push_back(memPos);
			twoToOneCounter++;
			nextIndx = nextIndx + 1;
			if (nextIndx == activeMemThreshold) {
				nextIndx = 0;
			}
		}

		CVector oneToTwoUnit = CVector(0, 0, 0) - twoToOneUnit;
		nodeOld = memOne;
		for (uint j = 0; j < numNewMemNodes; j++) {
			divAuxData.tmp2VecMem.push_back(nodeOld);
			nodeNew = nodeOld + memNewSpacing * twoToOneUnit;
			nodeOld = nodeNew;
		}

		divAuxData.tmp2MemActiveCounts.push_back(divAuxData.tmp2VecMem.size());
		for (uint j = 0; j < membThreshold; j++) {
			index = i * maxAllNodePerCell + j;
			if (j < divAuxData.tmp2VecMem.size()) {
				divAuxData.tmpXPos2_M[index] = divAuxData.tmp2VecMem[j].x;
				divAuxData.tmpYPos2_M[index] = divAuxData.tmp2VecMem[j].y;
				divAuxData.tmpIsActive2_M[index] = true;
			} else {
				divAuxData.tmpIsActive2_M[index] = false;
			}
		}

		////////////////////////////////
		//// copy internal nodes ///////
		////////////////////////////////
		CVector tmpCell1Center(0, 0, 0);
		for (uint j = 0; j < divAuxData.tmp1Vec.size(); j++) {
			tmpCell1Center = tmpCell1Center + divAuxData.tmp1Vec[j];
		}
		tmpCell1Center = tmpCell1Center / divAuxData.tmp1Vec.size();
		CVector shiftVec1 = cell1Center - tmpCell1Center;
		for (uint j = 0; j < divAuxData.tmp1Vec.size(); j++) {
			divAuxData.tmp1Vec[j] = divAuxData.tmp1Vec[j] + shiftVec1;
		}

		CVector tmpCell2Center(0, 0, 0);
		for (uint j = 0; j < divAuxData.tmp2Vec.size(); j++) {
			tmpCell2Center = tmpCell2Center + divAuxData.tmp2Vec[j];
		}
		tmpCell2Center = tmpCell2Center / divAuxData.tmp2Vec.size();
		CVector shiftVec2 = cell2Center - tmpCell2Center;
		for (uint j = 0; j < divAuxData.tmp2Vec.size(); j++) {
			divAuxData.tmp2Vec[j] = divAuxData.tmp2Vec[j] + shiftVec2;
		}

		divAuxData.tmp1InternalActiveCounts.push_back(
				divAuxData.tmp1Vec.size());
		divAuxData.tmp2InternalActiveCounts.push_back(
				divAuxData.tmp2Vec.size());

		for (uint j = membThreshold; j < maxAllNodePerCell; j++) {
			index = i * maxAllNodePerCell + j;
			uint shift_j = j - membThreshold;
			if (shift_j < divAuxData.tmp1Vec.size()) {
				divAuxData.tmpXPos1_M[index] = divAuxData.tmp1Vec[shift_j].x;
				divAuxData.tmpYPos1_M[index] = divAuxData.tmp1Vec[shift_j].y;
				divAuxData.tmpIsActive1_M[index] = true;
			} else {
				divAuxData.tmpIsActive1_M[index] = false;
			}
			if (shift_j < divAuxData.tmp2Vec.size()) {
				divAuxData.tmpXPos2_M[index] = divAuxData.tmp2Vec[shift_j].x;
				divAuxData.tmpYPos2_M[index] = divAuxData.tmp2Vec[shift_j].y;
				divAuxData.tmpIsActive2_M[index] = true;
			} else {
				divAuxData.tmpIsActive2_M[index] = false;
			}
		}
	}
}

void SceCells::copyFirstCellArr_M() {
	uint maxAllNodePerCell = allocPara_m.maxAllNodePerCell;
	uint index, oriIndex;
	for (uint i = 0; i < divAuxData.toBeDivideCount; i++) {
		uint cellRank = divAuxData.tmpCellRank_M[i];
		for (uint j = 0; j < maxAllNodePerCell; j++) {
			index = cellRank * maxAllNodePerCell + j
					+ allocPara_m.bdryNodeCount;
			oriIndex = i * maxAllNodePerCell + j;
			nodes->getInfoVecs().nodeLocX[index] =
					divAuxData.tmpXPos1_M[oriIndex];
			nodes->getInfoVecs().nodeLocY[index] =
					divAuxData.tmpYPos1_M[oriIndex];
			nodes->getInfoVecs().nodeIsActive[index] =
					divAuxData.tmpIsActive1_M[oriIndex];
		}
	}
}

void SceCells::copySecondCellArr_M() {
	uint maxAllNodePerCell = allocPara_m.maxAllNodePerCell;
	uint index, oriIndex;
	for (uint i = 0; i < divAuxData.toBeDivideCount; i++) {
		uint cellRank = allocPara_m.currentActiveCellCount + i;
		for (uint j = 0; j < maxAllNodePerCell; j++) {
			index = cellRank * maxAllNodePerCell + j
					+ allocPara_m.bdryNodeCount;
			oriIndex = i * maxAllNodePerCell + j;
			nodes->getInfoVecs().nodeLocX[index] =
					divAuxData.tmpXPos2_M[oriIndex];
			nodes->getInfoVecs().nodeLocY[index] =
					divAuxData.tmpYPos2_M[oriIndex];
			nodes->getInfoVecs().nodeIsActive[index] =
					divAuxData.tmpIsActive2_M[oriIndex];
		}
	}
}

void SceCells::updateActiveCellCount_M() {
	allocPara_m.currentActiveCellCount = allocPara_m.currentActiveCellCount
			+ divAuxData.toBeDivideCount;
	NodeAllocPara_M para_m = nodes->getAllocParaM();
	para_m.currentActiveCellCount = allocPara_m.currentActiveCellCount;
	nodes->setAllocParaM(para_m);
}

void SceCells::markIsDivideFalse_M() {
	thrust::fill(cellInfoVecs.isDivided.begin(),
			cellInfoVecs.isDivided.begin() + allocPara_m.currentActiveCellCount,
			false);
}

void SceCells::adjustNodeVel_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin()))
					+ allocPara_m.bdryNodeCount + totalNodeCountForActiveCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin())),
			ForceZero());
}

void SceCells::moveNodes_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin()))
					+ totalNodeCountForActiveCells + allocPara_m.bdryNodeCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeLocX.begin(),
							nodes->getInfoVecs().nodeLocY.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeLocX.begin(),
							nodes->getInfoVecs().nodeLocY.begin())),
			SaxpyFunctorDim2(dt));
}

void SceCells::applyMemTension_M() {
	totalNodeCountForActiveCells = allocPara_m.currentActiveCellCount
			* allocPara_m.maxAllNodePerCell;
	uint maxAllNodePerCell = allocPara_m.maxAllNodePerCell;
	thrust::counting_iterator<uint> iBegin(0);
	thrust::counting_iterator<uint> countingEnd(totalNodeCountForActiveCells);

	double* nodeLocXAddr = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeLocX[0]));
	double* nodeLocYAddr = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeLocY[0]));
	bool* nodeIsActiveAddr = thrust::raw_pointer_cast(
			&(nodes->getInfoVecs().nodeIsActive[0]));

	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							thrust::make_permutation_iterator(
									cellInfoVecs.activeMembrNodeCounts.begin(),
									make_transform_iterator(iBegin,
											DivideFunctor(maxAllNodePerCell))),
							make_transform_iterator(iBegin,
									DivideFunctor(maxAllNodePerCell)),
							make_transform_iterator(iBegin,
									ModuloFunctor(maxAllNodePerCell)),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara_m.bdryNodeCount)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							thrust::make_permutation_iterator(
									cellInfoVecs.activeMembrNodeCounts.begin(),
									make_transform_iterator(iBegin,
											DivideFunctor(maxAllNodePerCell))),
							make_transform_iterator(iBegin,
									DivideFunctor(maxAllNodePerCell)),
							make_transform_iterator(iBegin,
									ModuloFunctor(maxAllNodePerCell)),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara_m.bdryNodeCount))
					+ totalNodeCountForActiveCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(nodes->getInfoVecs().nodeVelX.begin(),
							nodes->getInfoVecs().nodeVelY.begin()))
					+ allocPara_m.bdryNodeCount,
			AddTensionForce(allocPara_m.bdryNodeCount, maxAllNodePerCell,
					nodeLocXAddr, nodeLocYAddr, nodeIsActiveAddr));
}

void SceCells::runAblationTest(AblationEvent& ablEvent) {
	for (uint i = 0; i < ablEvent.ablationCells.size(); i++) {
		int cellRank = ablEvent.ablationCells[i].cellNum;
		std::vector<uint> removeSeq = ablEvent.ablationCells[i].nodeNums;
		cellInfoVecs.activeNodeCountOfThisCell[cellRank] =
				cellInfoVecs.activeNodeCountOfThisCell[cellRank]
						- removeSeq.size();
		nodes->removeNodes(cellRank, removeSeq);
	}
}

void SceCells::computeCenterPos_M() {
	uint totalNodeCountForActiveCells = allocPara_m.currentActiveCellCount
			* allocPara_m.maxAllNodePerCell;
	thrust::counting_iterator<uint> iBegin(0);
	thrust::counting_iterator<uint> countingEnd(totalNodeCountForActiveCells);
	uint totalInternalActiveNodeCount = thrust::reduce(
			cellInfoVecs.activeIntnlNodeCounts.begin(),
			cellInfoVecs.activeIntnlNodeCounts.begin()
					+ allocPara_m.currentActiveCellCount);

	thrust::copy_if(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_transform_iterator(iBegin,
									DivideFunctor(
											allocPara_m.maxAllNodePerCell)),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_transform_iterator(iBegin,
									DivideFunctor(
											allocPara_m.maxAllNodePerCell)),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount))
					+ totalNodeCountForActiveCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(
							nodes->getInfoVecs().nodeIsActive.begin(),
							nodes->getInfoVecs().nodeCellType.begin()))
					+ allocPara_m.bdryNodeCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellNodeInfoVecs.cellRanks.begin(),
							cellNodeInfoVecs.activeXPoss.begin(),
							cellNodeInfoVecs.activeYPoss.begin())),
			ActiveAndInternal());

// TODO: double check if cell type is initialized properly.

	thrust::reduce_by_key(cellNodeInfoVecs.cellRanks.begin(),
			cellNodeInfoVecs.cellRanks.begin() + totalInternalActiveNodeCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellNodeInfoVecs.activeXPoss.begin(),
							cellNodeInfoVecs.activeYPoss.begin(),
							cellNodeInfoVecs.activeZPoss.begin())),
			cellInfoVecs.cellRanksTmpStorage.begin(),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin())),
			thrust::equal_to<uint>(), CVec3Add());
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin()))
					+ allocPara_m.currentActiveCellCount,
			cellInfoVecs.activeIntnlNodeCounts.begin(),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(),
							cellInfoVecs.centerCoordZ.begin())), CVec3Divide());
}

void SceCells::growAtRandom_M(double dt) {
	totalNodeCountForActiveCells = allocPara_m.currentActiveCellCount
			* allocPara_m.maxAllNodePerCell;

// randomly select growth direction and speed.
	randomizeGrowth_M();

//std::cout << "after copy grow info" << std::endl;
	updateGrowthProgress_M();
//std::cout << "after update growth progress" << std::endl;
	decideIsScheduleToGrow_M();
//std::cout << "after decode os schedule to grow" << std::endl;
	computeCellTargetLength_M();
//std::cout << "after compute cell target length" << std::endl;
	computeDistToCellCenter_M();
//std::cout << "after compute dist to center" << std::endl;
	findMinAndMaxDistToCenter_M();
//std::cout << "after find min and max dist" << std::endl;
	computeLenDiffExpCur_M();
//std::cout << "after compute diff " << std::endl;
	stretchCellGivenLenDiff_M();

	addPointIfScheduledToGrow_M();
//std::cout << "after adding node" << std::endl;
}

void SceCells::divide2D_M() {
	bool isDivisionPresent = decideIfGoingToDivide_M();
	if (!isDivisionPresent) {
		return;
	}
	copyCellsPreDivision_M();
	createTwoNewCellArr_M();
	copyFirstCellArr_M();
	copySecondCellArr_M();
	updateActiveCellCount_M();
	markIsDivideFalse_M();
}

void SceCells::distributeCellGrowthProgress_M() {
	totalNodeCountForActiveCells = allocPara_m.currentActiveCellCount
			* allocPara_m.maxAllNodePerCell;
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::counting_iterator<uint> countingEnd(totalNodeCountForActiveCells);

	thrust::copy(
			thrust::make_permutation_iterator(
					cellInfoVecs.growthProgress.begin(),
					make_transform_iterator(countingBegin,
							DivideFunctor(allocPara_m.maxAllNodePerCell))),
			thrust::make_permutation_iterator(
					cellInfoVecs.growthProgress.begin(),
					make_transform_iterator(countingEnd,
							DivideFunctor(allocPara_m.maxAllNodePerCell))),
			nodes->getInfoVecs().nodeGrowPro.begin()
					+ allocPara_m.bdryNodeCount);
}

void SceCells::allComponentsMove_M() {
	//
	moveNodes_M();
	//TODO: remove this temperary solution.
	//adjustNodeVel_M();
}

void SceCells::randomizeGrowth_M() {
	thrust::counting_iterator<uint> countingBegin(0);
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.isRandGrowInited.begin(),
							countingBegin)),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.isRandGrowInited.begin(),
							countingBegin))
					+ allocPara_m.currentActiveCellCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.growthSpeed.begin(),
							cellInfoVecs.growthXDir.begin(),
							cellInfoVecs.growthYDir.begin(),
							cellInfoVecs.isRandGrowInited.begin())),
			AssignRandIfNotInit(growthAuxData.randomGrowthSpeedMin,
					growthAuxData.randomGrowthSpeedMax,
					allocPara_m.currentActiveCellCount,
					growthAuxData.randGenAuxPara));
}

void SceCells::updateGrowthProgress_M() {
	thrust::transform(cellInfoVecs.growthSpeed.begin(),
			cellInfoVecs.growthSpeed.begin()
					+ allocPara_m.currentActiveCellCount,
			cellInfoVecs.growthProgress.begin(),
			cellInfoVecs.growthProgress.begin(), SaxpyFunctorWithMaxOfOne(dt));
}

void SceCells::decideIsScheduleToGrow_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.lastCheckPoint.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.lastCheckPoint.begin()))
					+ allocPara.currentActiveCellCount,
			cellInfoVecs.isScheduledToGrow.begin(),
			PtCondiOp(miscPara.growThreshold));
}

void SceCells::computeCellTargetLength_M() {
	thrust::transform(cellInfoVecs.growthProgress.begin(),
			cellInfoVecs.growthProgress.begin()
					+ allocPara_m.currentActiveCellCount,
			cellInfoVecs.expectedLength.begin(),
			CompuTarLen(bioPara.cellInitLength, bioPara.cellFinalLength));
}

void SceCells::computeDistToCellCenter_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_permutation_iterator(
									cellInfoVecs.centerCoordX.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.centerCoordY.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeIsActive.begin()
									+ allocPara_m.bdryNodeCount)),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							make_permutation_iterator(
									cellInfoVecs.centerCoordX.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.centerCoordY.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							nodes->getInfoVecs().nodeLocX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeLocY.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeIsActive.begin()
									+ allocPara_m.bdryNodeCount))
					+ totalNodeCountForActiveCells,
			cellNodeInfoVecs.distToCenterAlongGrowDir.begin(), CompuDist());
}

void SceCells::findMinAndMaxDistToCenter_M() {
	thrust::reduce_by_key(
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara_m.maxAllNodePerCell)),
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara_m.maxAllNodePerCell))
					+ totalNodeCountForActiveCells,
			cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
			cellInfoVecs.cellRanksTmpStorage.begin(),
			cellInfoVecs.smallestDistance.begin(), thrust::equal_to<uint>(),
			thrust::minimum<double>());

// for nodes of each cell, find the maximum distance from the node to the corresponding
// cell center along the pre-defined growth direction.

	thrust::reduce_by_key(
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara_m.maxAllNodePerCell)),
			make_transform_iterator(countingBegin,
					DivideFunctor(allocPara_m.maxAllNodePerCell))
					+ totalNodeCountForActiveCells,
			cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
			cellInfoVecs.cellRanksTmpStorage.begin(),
			cellInfoVecs.biggestDistance.begin(), thrust::equal_to<uint>(),
			thrust::maximum<double>());
}

void SceCells::computeLenDiffExpCur_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.smallestDistance.begin(),
							cellInfoVecs.biggestDistance.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.smallestDistance.begin(),
							cellInfoVecs.biggestDistance.begin()))
					+ allocPara_m.currentActiveCellCount,
			cellInfoVecs.lengthDifference.begin(), CompuDiff());
}

void SceCells::stretchCellGivenLenDiff_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(
							cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
							make_permutation_iterator(
									cellInfoVecs.lengthDifference.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara_m.bdryNodeCount,
							make_transform_iterator(countingBegin,
									ModuloFunctor(
											allocPara_m.maxAllNodePerCell)))),
			thrust::make_zip_iterator(
					thrust::make_tuple(
							cellNodeInfoVecs.distToCenterAlongGrowDir.begin(),
							make_permutation_iterator(
									cellInfoVecs.lengthDifference.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthXDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							make_permutation_iterator(
									cellInfoVecs.growthYDir.begin(),
									make_transform_iterator(countingBegin,
											DivideFunctor(
													allocPara_m.maxAllNodePerCell))),
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara_m.bdryNodeCount,
							make_transform_iterator(countingBegin,
									ModuloFunctor(
											allocPara_m.maxAllNodePerCell))))
					+ totalNodeCountForActiveCells,
			thrust::make_zip_iterator(
					thrust::make_tuple(
							nodes->getInfoVecs().nodeVelX.begin()
									+ allocPara_m.bdryNodeCount,
							nodes->getInfoVecs().nodeVelY.begin()
									+ allocPara_m.bdryNodeCount)),
			ApplyStretchForce_M(bioPara.elongationCoefficient,
					allocPara_m.maxMembrNodePerCell));
}

void SceCells::addPointIfScheduledToGrow_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isScheduledToGrow.begin(),
							cellInfoVecs.activeIntnlNodeCounts.begin(),
							cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(), countingBegin,
							cellInfoVecs.lastCheckPoint.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isScheduledToGrow.begin(),
							cellInfoVecs.activeIntnlNodeCounts.begin(),
							cellInfoVecs.centerCoordX.begin(),
							cellInfoVecs.centerCoordY.begin(), countingBegin,
							cellInfoVecs.lastCheckPoint.begin()))
					+ allocPara_m.currentActiveCellCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isScheduledToGrow.begin(),
							cellInfoVecs.activeIntnlNodeCounts.begin(),
							cellInfoVecs.lastCheckPoint.begin())),
			AddPtOp(allocPara_m.maxAllNodePerCell, miscPara.addNodeDistance,
					miscPara.minDistanceToOtherNode,
					growthAuxData.nodeIsActiveAddress,
					growthAuxData.nodeXPosAddress,
					growthAuxData.nodeYPosAddress, time(NULL),
					miscPara.growThreshold));
}

bool SceCells::decideIfGoingToDivide_M() {
	thrust::transform(
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.lengthDifference.begin(),
							cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.activeIntnlNodeCounts.begin())),
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.lengthDifference.begin(),
							cellInfoVecs.expectedLength.begin(),
							cellInfoVecs.growthProgress.begin(),
							cellInfoVecs.activeIntnlNodeCounts.begin()))
					+ allocPara_m.currentActiveCellCount,
			thrust::make_zip_iterator(
					thrust::make_tuple(cellInfoVecs.isDivided.begin(),
							cellInfoVecs.growthProgress.begin())),
			CompuIsDivide(miscPara.isDivideCriticalRatio,
					allocPara_m.maxAllNodePerCell));
// sum all bool values which indicate whether the cell is going to divide.
// toBeDivideCount is the total number of cells going to divide.
	divAuxData.toBeDivideCount = thrust::reduce(cellInfoVecs.isDivided.begin(),
			cellInfoVecs.isDivided.begin() + allocPara_m.currentActiveCellCount,
			(uint) (0));
	if (divAuxData.toBeDivideCount > 0) {
		return true;
	} else {
		return false;
	}
}

AniRawData SceCells::obtainAniRawData(AnimationCriteria& aniCri) {
	AniRawData rawAniData;

	std::vector<std::pair<uint, uint> > pairs =
			nodes->obtainPossibleNeighborPairs_M();
	cout << "size of potential pairs = " << pairs.size() << endl;

// unordered_map is more efficient than map, but it is a c++ 11 feature
// and c++ 11 seems to be incompatible with Thrust.
	IndexMap locIndexToAniIndexMap;

// Doesn't have to copy the entire nodeLocX array.
// Only copy the first half will be sufficient
	thrust::host_vector<double> hostTmpVectorLocX =
			nodes->getInfoVecs().nodeLocX;
	thrust::host_vector<double> hostTmpVectorLocY =
			nodes->getInfoVecs().nodeLocY;
	thrust::host_vector<bool> hostIsActiveVec =
			nodes->getInfoVecs().nodeIsActive;
	thrust::host_vector<int> hostBondVec = nodes->getInfoVecs().nodeAdhereIndex;
	thrust::host_vector<SceNodeType> hostTmpVectorNodeType =
			nodes->getInfoVecs().nodeCellType;

	thrust::host_vector<uint> curActiveMemNodeCounts =
			cellInfoVecs.activeMembrNodeCounts;

	uint activeCellCount = allocPara_m.currentActiveCellCount;
	uint maxNodePerCell = allocPara_m.maxAllNodePerCell;
	uint maxMemNodePerCell = allocPara_m.maxMembrNodePerCell;
	uint beginIndx = allocPara_m.bdryNodeCount;
//uint endIndx = beginIndx + activeCellCount * maxNodePerCell;

//uint cellRank1, nodeRank1, cellRank2, nodeRank2;
	CVector tmpPos;
	uint index1;
	int index2;
	std::vector<BondInfo> bondInfoVec;

	double node1X, node1Y;
	double node2X, node2Y;
	double aniVal;

	for (uint i = 0; i < activeCellCount; i++) {
		for (uint j = 0; j < maxMemNodePerCell; j++) {
			index1 = beginIndx + i * maxNodePerCell + j;
			if (hostIsActiveVec[index1] == true) {
				index2 = hostBondVec[index1];
				if (index2 > index1 && index2 != -1) {
					BondInfo bond;
					bond.cellRank1 = i;
					bond.pos1 = CVector(hostTmpVectorLocX[index1],
							hostTmpVectorLocY[index1], 0);
					bond.cellRank2 = (index2 - beginIndx) / maxNodePerCell;
					bond.pos2 = CVector(hostTmpVectorLocX[index2],
							hostTmpVectorLocY[index2], 0);
					bondInfoVec.push_back(bond);
				}
			}
		}
	}

	rawAniData.bondsArr = bondInfoVec;

	uint curIndex = 0;

	for (uint i = 0; i < activeCellCount; i++) {
		for (uint j = 0; j < curActiveMemNodeCounts[i]; j++) {
			index1 = beginIndx + i * maxNodePerCell + j;
			if (j == curActiveMemNodeCounts[i] - 1) {
				index2 = beginIndx + i * maxNodePerCell;
			} else {
				index2 = beginIndx + i * maxNodePerCell + j + 1;
			}

			if (hostIsActiveVec[index1] == true
					&& hostIsActiveVec[index2] == true) {
				node1X = hostTmpVectorLocX[index1];
				node1Y = hostTmpVectorLocY[index1];
				node2X = hostTmpVectorLocX[index2];
				node2Y = hostTmpVectorLocY[index2];
				IndexMap::iterator it = locIndexToAniIndexMap.find(index1);
				if (it == locIndexToAniIndexMap.end()) {
					locIndexToAniIndexMap.insert(
							std::pair<uint, uint>(index1, curIndex));
					curIndex++;
					tmpPos = CVector(node1X, node1Y, 0);
					aniVal = hostTmpVectorNodeType[index1];
					rawAniData.aniNodePosArr.push_back(tmpPos);
					rawAniData.aniNodeVal.push_back(aniVal);
				}
				it = locIndexToAniIndexMap.find(index2);
				if (it == locIndexToAniIndexMap.end()) {
					locIndexToAniIndexMap.insert(
							std::pair<uint, uint>(index2, curIndex));
					curIndex++;
					tmpPos = CVector(node2X, node2Y, 0);
					aniVal = hostTmpVectorNodeType[index2];
					rawAniData.aniNodePosArr.push_back(tmpPos);
					rawAniData.aniNodeVal.push_back(aniVal);
				}

				it = locIndexToAniIndexMap.find(index1);
				uint aniIndex1 = it->second;
				it = locIndexToAniIndexMap.find(index2);
				uint aniIndex2 = it->second;

				LinkAniData linkData;
				linkData.node1Index = aniIndex1;
				linkData.node2Index = aniIndex2;
				rawAniData.memLinks.push_back(linkData);
			}
		}
	}

	for (uint i = 0; i < pairs.size(); i++) {
		uint node1Index = pairs[i].first;
		uint node2Index = pairs[i].second;
		node1X = hostTmpVectorLocX[node1Index];
		node1Y = hostTmpVectorLocY[node1Index];

		node2X = hostTmpVectorLocX[node2Index];
		node2Y = hostTmpVectorLocY[node2Index];

		if (aniCri.isPairQualify_M(node1X, node1Y, node2X, node2Y)) {
			IndexMap::iterator it = locIndexToAniIndexMap.find(pairs[i].first);
			if (it == locIndexToAniIndexMap.end()) {
				locIndexToAniIndexMap.insert(
						std::pair<uint, uint>(pairs[i].first, curIndex));
				curIndex++;
				tmpPos = CVector(node1X, node1Y, 0);
				aniVal = hostTmpVectorNodeType[index1];
				rawAniData.aniNodePosArr.push_back(tmpPos);
				rawAniData.aniNodeVal.push_back(aniVal);
			}
			it = locIndexToAniIndexMap.find(pairs[i].second);
			if (it == locIndexToAniIndexMap.end()) {
				locIndexToAniIndexMap.insert(
						std::pair<uint, uint>(pairs[i].second, curIndex));
				curIndex++;
				tmpPos = CVector(node2X, node2Y, 0);
				aniVal = hostTmpVectorNodeType[index1];
				rawAniData.aniNodePosArr.push_back(tmpPos);
				rawAniData.aniNodeVal.push_back(aniVal);
			}

			it = locIndexToAniIndexMap.find(pairs[i].first);
			uint aniIndex1 = it->second;
			it = locIndexToAniIndexMap.find(pairs[i].second);
			uint aniIndex2 = it->second;

			LinkAniData linkData;
			linkData.node1Index = aniIndex1;
			linkData.node2Index = aniIndex2;
			rawAniData.internalLinks.push_back(linkData);
		}
	}

	return rawAniData;
}

void SceCells::copyInitActiveNodeCount_M(
		std::vector<uint>& initMembrActiveNodeCounts,
		std::vector<uint>& initIntnlActiveNodeCounts) {
	std::cout << "size 1 = " << initMembrActiveNodeCounts.size() << std::endl;
	std::cout << "size 2 = " << cellInfoVecs.activeMembrNodeCounts.size()
			<< std::endl;
	std::cout << "size 3 = " << initIntnlActiveNodeCounts.size() << std::endl;
	std::cout << "size 4 = " << cellInfoVecs.activeIntnlNodeCounts.size()
			<< std::endl;
	std::cout.flush();

	thrust::copy(initMembrActiveNodeCounts.begin(),
			initMembrActiveNodeCounts.end(),
			cellInfoVecs.activeMembrNodeCounts.begin());
	thrust::copy(initIntnlActiveNodeCounts.begin(),
			initIntnlActiveNodeCounts.end(),
			cellInfoVecs.activeIntnlNodeCounts.begin());
}

VtkAnimationData SceCells::outputVtkData(AniRawData& rawAniData,
		AnimationCriteria& aniCri) {
	VtkAnimationData vtkData;
	for (uint i = 0; i < rawAniData.aniNodePosArr.size(); i++) {
		PointAniData ptAniData;
		ptAniData.pos = rawAniData.aniNodePosArr[i];
		ptAniData.colorScale = rawAniData.aniNodeVal[i];
		vtkData.pointsAniData.push_back(ptAniData);
	}
	for (uint i = 0; i < rawAniData.internalLinks.size(); i++) {
		LinkAniData linkData = rawAniData.internalLinks[i];
		vtkData.linksAniData.push_back(linkData);
	}
	for (uint i = 0; i < rawAniData.memLinks.size(); i++) {
		LinkAniData linkData = rawAniData.memLinks[i];
		vtkData.linksAniData.push_back(linkData);
	}
	vtkData.isArrowIncluded = false;
	return vtkData;
}

void SceCells::copyToGPUConstMem() {
	double membrEquLenCPU =
			globalConfigVars.getConfigValue("MembrEquLen").toDouble();
	double membrStiffCPU =
			globalConfigVars.getConfigValue("MembrStiff").toDouble();
	cudaMemcpyToSymbol(membrEquLen, &membrEquLenCPU, sizeof(double));
	cudaMemcpyToSymbol(membrStiff, &membrStiffCPU, sizeof(double));
}
