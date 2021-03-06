local MinEntropy, Parent = torch.class('nn.MinEntropy', 'nn.Module')

local function compute_consistency(top_roi, x_max, y_max)
	local nROI    = top_roi:size(1)
	local roi_dim = top_roi:size(2)
	
	--compute distance
	local dist = torch.CudaTensor(nROI,nROI):fill(-1)
	top_roi.salc.ME_ComputeDistance( self, top_roi, dist,
																	nROI, roi_dim,
																	x_max, y_max, 1)
	--compute inds
	local inds   = torch.FloatTensor(nROI):fill(0)
	local clique = torch.FloatTensor(200):fill(-1)
	local dist_float = dist:float()
	inds.salc.ME_LocalConsistency(self, dist_float, inds, clique, nROI, 0.7)
	
	return inds
end


local function trans_inds(inds)
	local inds_output = torch.Tensor(inds:size(1),3):fill(-1)
	inds_output.salc.ME_TransIndsFast(self, inds_output, inds, inds:size(1))
	
	local temp_val, temp_inds = torch.sort(inds_output[{{}, 1}])
	local temp = inds_output[{{},3}]:clone()
	inds_output.salc.ME_ReTransInds(self, inds_output, temp, temp_val, 
																	temp_inds:float(),  inds_output:size(1))
	--trans to gpu
	local inds_output_gpu = nil
	inds_output_gpu              = inds_output:cuda()
	return inds_output_gpu
end

function MinEntropy:__init()
	Parent.__init(self)
	self.NTOP = NTOP or 100
	self.inds = nil
	self.LME_train_net = nil
	self.LME_test_net  = nil
	self.me_net_temp = nn.Sequential():
		add(nn.ParallelTable():
			add(nn.Sequential():
				add(cudnn.SpatialSoftMax()):
				add(RoiReshaper:RestoreShape(4)):
				add(nn.Squeeze(4))
			):
			add(nn.Sequential():
				add(cudnn.SpatialSoftMax()):
				add(nn.Squeeze(4))
			)
		):
		add(nn.CMulTable()):cuda()
end

function MinEntropy:ConstructTrainNet(num,dim)
	local train_net = nn.Sequential():
		add(nn.ParallelTable():
			add(nn.Sequential():
				add(cudnn.SpatialSoftMax()):
				add(nn.View(-1,num,dim))
			):
			add(nn.Sequential():
				add(cudnn.SpatialSoftMax()):
				add(nn.Squeeze(4))
			)
		):
		add(nn.CMulTable()):
		add(nn.Sum(2)):
		add(nn.FixProb()):cuda()
	return train_net
end



function MinEntropy:ConstructTestNet(num, dim)
	--construct
	local test_net = nn.Sequential():
		add(nn.ParallelTable():
			add(nn.Sequential():
				add(cudnn.SpatialSoftMax()):
				add(nn.View(-1,num,dim))
			):
			add(nn.Sequential():
				add(cudnn.SpatialSoftMax()):
				add(nn.Squeeze(4))
			)
		):
		add(nn.CMulTable()):cuda()
	return test_net
end

function MinEntropy:ConstructTest2ImageNet()
	--construct
	local test_net2img = nn.Sequential():
		add(nn.Sum(2)):
		add(nn.FixProb()):cuda()
	return test_net2img
end

function MinEntropy:ComputeIndsFast(rois, ClsWeight)
	local x_max = rois[{{}, 3}]:max()  --x_max and y_max is image width and height
	local y_max = rois[{{}, 4}]:max()
	local score_sort_ids = nil
	_, score_sort_ids = torch.sort(-ClsWeight)
	
	--select top n score rois
	local ntop     = math.min(rois:size(1), self.NTOP)
	local top_roi  = torch.CudaTensor(ntop, rois:size(2)):fill(0)
	local mask     = torch.CudaByteTensor(#rois):fill(0)
	mask:indexFill(1,score_sort_ids[{{1,ntop}}],1)
	top_roi=rois:maskedSelect(mask):reshape(ntop,rois:size(2))

	--compute local consistency and local clustering
	local inds = torch.Tensor(ntop):fill(1)
	inds = compute_consistency(top_roi, x_max, y_max)
	
	--assign local inds for all rois
	local inds_all  = torch.FloatTensor(mask:size(1)):fill(-1)
	local mask_all  = mask[{{},1}]:float()
	local nAllRois  = mask_all:size(1)
	local nTopLocal = inds:max()
	inds.salc.ME_AssignIndsFast(self, inds_all, inds:float(), mask_all, nAllRois, nTopLocal)
	
	
	local output_inds = trans_inds(inds_all:float())
	
	return output_inds, mask_all
end

function MinEntropy:updateOutput(input)
	-- input contains:
	-- input[1][1] : cls stream by softmax        --nRois * 20
	-- input[1][2] : cls weight stream by exp     --nRois * 20
	-- input[2]    : Rois                         --nRois * 5
	local temp = input
	local input = {}
	input[1] = temp
	input[2] = scale0_rois[1]:cuda()


	local inCls  = input[1][1]              -- cls stream
	local inClsW = input[1][2][{1,{},{},1}] -- cls weight stream
	local rois   = input[2]:cuda()
	local nDim   = inCls:size(2)  -- number of object classes, 20 for PASCAL
	
	--compute inds: a nRoi dim vector
	ScorePred = self.me_net_temp:forward(input[1])[1]
	ScoreTmp = ScorePred:max(2):view(-1)


	local box_score = inCls
	BOX_SCORE = box_score

	--local ScoreTmp = self.me_net_temp:forward(input[1])[1]
	self.inds = self:ComputeIndsFast(rois, ScoreTmp)

	--Merge input by inds
	local nOutRoi = self.inds[{{},1}]:max()
	self.merged_input = {}
	self.merged_input[1] = torch.CudaTensor(nOutRoi, nDim):fill(0)
	local merged_input2  = torch.CudaTensor(nOutRoi, nDim):fill(0)
	inCls.salc.ME_MergeInputFast( self, inCls, inClsW,    --function input
																self.merged_input[1],   --function output 1
																merged_input2,          --function output 2
																self.inds, nDim, self.inds:size(1))  --inds
	self.merged_input[2] = nn.View(1,nOutRoi,nDim,1):cuda():forward(merged_input2)
	
	if false then --self.train then 
		--construct train net
		self.LME_train_net = self:ConstructTrainNet(nOutRoi, nDim)
		self.output = self.LME_train_net:forward(self.merged_input)
		return self.output
	else
		self.LME_train_net = self:ConstructTrainNet(nOutRoi, nDim)
		self.LME_train_net:forward(self.merged_input)

		--construct test net
		local LME_test_net    = self:ConstructTestNet(nOutRoi, nDim)
		local LME_test2im_net = self:ConstructTest2ImageNet()
		
		local merged_box_scores = LME_test_net:forward(self.merged_input)
		local im_score = LME_test2im_net:forward(merged_box_scores)
		
		local boxes_score = torch.CudaTensor(1, rois:size(1), 20):fill(0)

		boxes_score.salc.ME_MergeScoresFast(self,
											            merged_box_scores, --input stream
																	boxes_score,       --output stream
																	self.inds,           --inds for cluster i
																	self.inds:size(1),   --loop number
																	self.inds[{{},2}]:max(), inCls:size(2))
		
		ScoreOutput = boxes_score
		self.output = im_score
		--self.output[1] = im_score
		--self.output[2] = boxes_score
		return self.output
	end
end

function MinEntropy:updateGradInput(input, gradOutput)
	-- input contains:
	-- input[1][1] : cls stream by softmax        --nRois * 20
	-- input[1][2] : cls weight stream by exp     --nRois * 20
	-- input[2]    : Rois                         --nRois * 5
	local temp = input
	local input = {}
	input[1] = temp
	input[2] = scale0_rois[1]:cuda()

	local inCls  = input[1][1]              -- cls stream
	local inClsW = input[1][2][{1,{},{},1}] -- cls weight stream
	local rois   = input[2]:cuda()
	
	-- init self.gradInput 
	self.gradInput       = {}
	self.gradInput[1]    = {}
	self.gradInput[1][1] = torch.CudaTensor( #input[1][1]):fill(0)
	self.gradInput[2]    = torch.FloatTensor(#input[2]   ):fill(0)
	local self_gradIput2 = torch.CudaTensor( #inClsW     ):fill(0)

	
	local gradInput  = self.LME_train_net:backward(self.merged_input, gradOutput)
	local gradInput1 = gradInput[1]
	local gradInput2 = gradInput[2][{1,{},{},1}]

	inCls.salc.ME_MergeGradsFast(self, self.gradInput[1][1], self_gradIput2,   --function output
															gradInput1,  gradInput2,                       --function input
															self.inds, self.inds:size(1),								   --inds and loop number
															self.inds[{{},2}]:max(), inCls:size(2))  
	self.gradInput[1][2] = nn.View(#input[1][2]):cuda():forward(self_gradIput2)

	self.gradInput = self.gradInput[1]
	return self.gradInput
end

