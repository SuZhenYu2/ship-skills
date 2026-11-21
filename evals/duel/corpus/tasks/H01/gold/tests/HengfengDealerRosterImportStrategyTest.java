package com.cbmc.biz.order.test.core.app.dealerroster.strategy;

import com.cbmc.biz.order.common.util.RestResultUtil;
import com.cbmc.biz.order.core.app.dealerroster.strategy.HengfengDealerRosterImportStrategy;
import com.cbmc.biz.order.core.domain.dealerroster.domain.EfDealerRosterDomainService;
import com.cbmc.biz.order.core.domain.message.sender.SmsNoticeSender;
import com.cbmc.biz.order.core.domain.dealerroster.dao.sdo.jooq.entities.tables.pojos.TEfDealerRoster;
import com.cbmc.biz.order.sdk.dealerroster.model.EfDealerRosterImportReqDTO;
import com.cbmc.biz.order.sdk.dealerroster.model.EfDealerRosterImportReqDTO.RosterImportData;
import com.cbmc.biz.order.sdk.dealerroster.model.EfDealerMetricsImportDTO;
import com.cbmc.biz.order.sdk.order.model.operation.EfDataImportRespDTO;
import com.cbmc.biz.order.sdk.constants.MarketingStatusEnum;
import com.cbmc.biz.order.sdk.constants.RosterDataSourceEnum;
import com.cbmc.mps.signup.sdk.dynamicpage.client.DynamicConfigSwitchClient;
import com.cbmc.mps.signup.sdk.dynamicpage.model.DynamicConfigSwitchRespDTO;
import com.cbmc.mps.signup.sdk.indexrecommend.client.IndexRecommendClient;
import com.cbmc.mps.signup.sdk.indexrecommend.model.IndexRecommendBatchUpsertReqDTO;
import com.cbmc.sdk.biz.finance.signup.model.evaluation.CoreIndexRecommendBatchAddOrUpdateReqDTO;
import com.cbmc.sdk.biz.finance.signup.service.CoreIndexRecommendService;
import com.ccbscf.biz.ci.constants.BankCategoryEnum;
import com.ccbscf.common.exception.CcbscfBizException;
import com.ccbscf.common.util.spring.SpringContextHolder;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.powermock.api.mockito.PowerMockito;
import org.powermock.core.classloader.annotations.PrepareForTest;
import org.powermock.modules.junit4.PowerMockRunner;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import static org.mockito.Matchers.any;
import static org.mockito.Matchers.anyList;
import static org.mockito.Matchers.anyString;
import static org.mockito.Matchers.anySet;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.doNothing;
import static org.junit.Assert.*;

/**
 * HengfengDealerRosterImportStrategy的单元测试类
 */
@RunWith(PowerMockRunner.class)
@PrepareForTest({SpringContextHolder.class})
public class HengfengDealerRosterImportStrategyTest {

    @InjectMocks
    private HengfengDealerRosterImportStrategy strategy;

    @Mock
    private EfDealerRosterDomainService efDealerRosterDomainService;

    @Mock
    private CoreIndexRecommendService coreIndexRecommendService;

    @Mock
    private SmsNoticeSender smsNoticeSender;

    @Mock
    private IndexRecommendClient indexRecommendClient;

    @Mock
    private DynamicConfigSwitchClient dynamicConfigSwitchClient;

    @Before
    public void setUp() {
        // Mock SpringContextHolder静态方法
        PowerMockito.mockStatic(SpringContextHolder.class);
        when(SpringContextHolder.getBean(HengfengDealerRosterImportStrategy.class)).thenReturn(strategy);
        // 默认走老链路
        when(dynamicConfigSwitchClient.querySwitch(any()))
                .thenReturn(RestResultUtil.success(new DynamicConfigSwitchRespDTO()));
    }

    // ==================== validate 方法测试 ====================

    /**
     * 测试validate方法 - 校验通过
     */
    @Test
    public void validate_Success_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertTrue(result.isEmpty());
    }

    /**
     * 测试validate方法 - 导入数据为空抛出异常
     */
    @Test(expected = CcbscfBizException.class)
    public void validate_EmptyData_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setRosterDatas(null);

        strategy.validate(reqDTO);
    }

    /**
     * 测试validate方法 - reqDTO为空抛出异常
     */
    @Test(expected = CcbscfBizException.class)
    public void validate_NullReqDTO_byAI() throws Exception {
        strategy.validate(null);
    }

    /**
     * 测试validate方法 - 推荐指标信息为空
     */
    @Test
    public void validate_MetricsEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setFkCorpCore("CORE001");
        reqDTO.setCorpNameCore("核心企业");
        reqDTO.setBankCode(BankCategoryEnum.HENGFENG);

        List<RosterImportData> rosterDatas = new ArrayList<>();
        RosterImportData data = new RosterImportData();
        data.setCorpNameDealer("经销商1");
        data.setRowNum(2);
        data.setMetricsImportData(null);
        rosterDatas.add(data);
        reqDTO.setRosterDatas(rosterDatas);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("推荐指标信息为空"));
    }

    /**
     * 测试validate方法 - 经销商名称去括号后为空
     */
    @Test
    public void validate_CorpNameDealerEmptyAfterRemoveParenthesis_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setFkCorpCore("CORE001");
        reqDTO.setCorpNameCore("核心企业");
        reqDTO.setBankCode(BankCategoryEnum.HENGFENG);

        List<RosterImportData> rosterDatas = new ArrayList<>();
        RosterImportData data = new RosterImportData();
        data.setCorpNameDealer("（）（）"); // 去括号后为空
        data.setRowNum(2);
        data.setMetricsImportData(buildValidMetricsImportDTO());
        rosterDatas.add(data);
        reqDTO.setRosterDatas(rosterDatas);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("经销商名称去括号后为空"));
    }

    /**
     * 测试validate方法 - 经销商名称等于核心企业名称
     */
    @Test
    public void validate_CorpNameDealerEqualsCorpNameCore_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setFkCorpCore("CORE001");
        reqDTO.setCorpNameCore("核心企业");
        reqDTO.setBankCode(BankCategoryEnum.HENGFENG);

        List<RosterImportData> rosterDatas = new ArrayList<>();
        RosterImportData data = new RosterImportData();
        data.setCorpNameDealer("核心企业"); // 与核心企业名称相同
        data.setRowNum(2);
        data.setMetricsImportData(buildValidMetricsImportDTO());
        rosterDatas.add(data);
        reqDTO.setRosterDatas(rosterDatas);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("经销商名称不能为本公司"));
    }

    /**
     * 测试validate方法 - 基本信息校验返回错误
     */
    @Test
    public void validate_BasicInfoError_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(Arrays.asList("经销商名称为空", "联系人姓名为空"));

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("经销商名称为空"));
    }

    // ==================== validateMetricsData 方法测试（通过validate间接测试） ====================

    /**
     * 测试validateMetricsData - 信息统计年度为空
     */
    @Test
    public void validate_MetricsYearEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setMetricsYear(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("信息统计年度为空"));
    }

    /**
     * 测试validateMetricsData - 信息统计年度格式错误
     */
    @Test
    public void validate_MetricsYearInvalidFormat_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setMetricsYear("abc");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("信息统计年度取值错误"));
    }

    /**
     * 测试validateMetricsData - 信息统计年度大于当前年份
     */
    @Test
    public void validate_MetricsYearGreaterThanCurrent_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setMetricsYear("2030");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("信息统计年度不可大于当前年份"));
    }

    /**
     * 测试validateMetricsData - 信息统计年度小于1000
     */
    @Test
    public void validate_MetricsYearLessThan1000_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setMetricsYear("99");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("信息统计年度取值错误"));
    }

    /**
     * 测试validateMetricsData - 合作年限为空
     */
    @Test
    public void validate_CooperationPeriodEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCooperationPeriod(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("合作年限为空"));
    }

    /**
     * 测试validateMetricsData - 合作年限取值无效
     */
    @Test
    public void validate_CooperationPeriodInvalid_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCooperationPeriod("无效值");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("合作年限取值错误"));
    }

    /**
     * 测试validateMetricsData - 是否为一级经销商为空
     */
    @Test
    public void validate_TierOneDealerFlagEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setTierOneDealerFlag(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("是否为一级经销商为空"));
    }

    /**
     * 测试validateMetricsData - 是否为一级经销商取值无效
     */
    @Test
    public void validate_TierOneDealerFlagInvalid_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setTierOneDealerFlag("无效值");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("是否为一级经销商取值错误"));
    }

    /**
     * 测试validateMetricsData - 经销商级别为空
     */
    @Test
    public void validate_DealerLevelEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setDealerLevel(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("经销商级别为空"));
    }

    /**
     * 测试validateMetricsData - 经销商级别取值无效
     */
    @Test
    public void validate_DealerLevelInvalid_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setDealerLevel("无效级别");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("经销商级别取值错误"));
    }

    /**
     * 测试validateMetricsData - 核心企业推荐额度为空
     */
    @Test
    public void validate_CoreRecommendedLimitEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCoreRecommendedLimit(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("核心企业推荐额度为空"));
    }

    /**
     * 测试validateMetricsData - 核心企业推荐额度格式错误
     */
    @Test
    public void validate_CoreRecommendedLimitInvalidFormat_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCoreRecommendedLimit("abc");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("核心企业推荐额度取值错误"));
    }

    /**
     * 测试validateMetricsData - 核心企业推荐额度小于等于0
     */
    @Test
    public void validate_CoreRecommendedLimitLessThanZero_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCoreRecommendedLimit("-100");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("核心企业推荐额度取值错误"));
    }

    /**
     * 测试validateMetricsData - 核心企业推荐额度为0
     */
    @Test
    public void validate_CoreRecommendedLimitEqualsZero_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCoreRecommendedLimit("0");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("核心企业推荐额度取值错误"));
    }

    /**
     * 测试validateMetricsData - 核心企业推荐额度超长
     */
    @Test
    public void validate_CoreRecommendedLimitOverLength_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCoreRecommendedLimit("99999999999999999.99");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("核心企业推荐额度超长"));
    }

    /**
     * 测试validateMetricsData - 核心企业推荐额度带逗号格式
     */
    @Test
    public void validate_CoreRecommendedLimitWithComma_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCoreRecommendedLimit("1,000,000");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertTrue(result.isEmpty()); // 带逗号格式应正确解析
    }

    /**
     * 测试validateMetricsData - 当年厂商任务量为空
     */
    @Test
    public void validate_CurrentYearTaskAmountEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCurrentYearTaskAmount(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("当年厂商任务量为空"));
    }

    /**
     * 测试validateMetricsData - 当年厂商任务量格式错误
     */
    @Test
    public void validate_CurrentYearTaskAmountInvalidFormat_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCurrentYearTaskAmount("abc");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("当年厂商任务量取值错误"));
    }

    /**
     * 测试validateMetricsData - 当年厂商任务量为负数
     */
    @Test
    public void validate_CurrentYearTaskAmountNegative_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCurrentYearTaskAmount("-100");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("当年厂商任务量取值错误"));
    }

    /**
     * 测试validateMetricsData - 当年厂商任务量超长
     */
    @Test
    public void validate_CurrentYearTaskAmountOverLength_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setCurrentYearTaskAmount("99999999999999999.99");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("当年厂商任务量超长"));
    }

    /**
     * 测试validateMetricsData - 上年进货总金额为空
     */
    @Test
    public void validate_LastYearPurchaseAmountEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearPurchaseAmount(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年针对核心企业进货总金额为空"));
    }

    /**
     * 测试validateMetricsData - 上年进货总金额格式错误
     */
    @Test
    public void validate_LastYearPurchaseAmountInvalidFormat_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearPurchaseAmount("abc");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年针对核心企业进货总金额取值错误"));
    }

    /**
     * 测试validateMetricsData - 上年进货总金额为负数
     */
    @Test
    public void validate_LastYearPurchaseAmountNegative_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearPurchaseAmount("-100");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年针对核心企业进货总金额取值错误"));
    }

    /**
     * 测试validateMetricsData - 上年进货总金额超长
     */
    @Test
    public void validate_LastYearPurchaseAmountOverLength_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearPurchaseAmount("99999999999999999.99");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年针对核心企业进货总金额超长"));
    }

    /**
     * 测试validateMetricsData - 上年度销售比重为空
     */
    @Test
    public void validate_LastYearCoreSalesRatioEmpty_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearCoreSalesRatio(null);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年度占核心企业销售比重为空"));
    }

    /**
     * 测试validateMetricsData - 上年度销售比重格式错误
     */
    @Test
    public void validate_LastYearCoreSalesRatioInvalidFormat_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearCoreSalesRatio("abc");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年度占核心企业销售比重取值错误"));
    }

    /**
     * 测试validateMetricsData - 上年度销售比重小于0
     */
    @Test
    public void validate_LastYearCoreSalesRatioLessThanZero_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearCoreSalesRatio("-10");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年度占核心企业销售比重取值错误"));
    }

    /**
     * 测试validateMetricsData - 上年度销售比重大于100
     */
    @Test
    public void validate_LastYearCoreSalesRatioGreaterThan100_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        reqDTO.getRosterDatas().get(0).getMetricsImportData().setLastYearCoreSalesRatio("150");

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertTrue(result.get(0).getErrorMsg().contains("上年度占核心企业销售比重取值错误"));
    }

    /**
     * 测试validate方法 - 多条数据，部分校验失败
     */
    @Test
    public void validate_MultipleRecordsPartialError_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setFkCorpCore("CORE001");
        reqDTO.setCorpNameCore("核心企业");
        reqDTO.setBankCode(BankCategoryEnum.HENGFENG);

        List<RosterImportData> rosterDatas = new ArrayList<>();
        // 第一条：校验通过
        RosterImportData data1 = new RosterImportData();
        data1.setCorpNameDealer("经销商1");
        data1.setContactName("联系人1");
        data1.setMobilePhone("13800138001");
        data1.setRowNum(2);
        data1.setMetricsImportData(buildValidMetricsImportDTO());
        rosterDatas.add(data1);

        // 第二条：推荐指标为空
        RosterImportData data2 = new RosterImportData();
        data2.setCorpNameDealer("经销商2");
        data2.setRowNum(3);
        data2.setMetricsImportData(null);
        rosterDatas.add(data2);

        reqDTO.setRosterDatas(rosterDatas);

        when(efDealerRosterDomainService.validateRosterImportDataBasicInfo(any(RosterImportData.class)))
                .thenReturn(new ArrayList<>());

        List<EfDataImportRespDTO.FileImportErrorMsgRespDTO> result = strategy.validate(reqDTO);

        assertNotNull(result);
        assertEquals(1, result.size());
        assertEquals(Integer.valueOf(3), result.get(0).getErrorRowNum());
    }

    // ==================== processImport 方法测试 ====================

    /**
     * 测试processImport方法 - 导入数据为空抛出异常
     */
    @Test(expected = CcbscfBizException.class)
    public void processImport_EmptyData_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setRosterDatas(null);

        strategy.processImport(reqDTO);
    }

    /**
     * 测试processImport方法 - reqDTO为空抛出异常
     */
    @Test(expected = CcbscfBizException.class)
    public void processImport_NullReqDTO_byAI() throws Exception {
        strategy.processImport(null);
    }

    /**
     * 测试processImport方法 - 全部新建经销商
     */
    @Test
    public void processImport_AllNew_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();

        // Mock 查询已存在经销商名单为空
        when(efDealerRosterDomainService.queryDealerRosterByFixedNameSet(anyString(), anyString(), any(BankCategoryEnum.class), anySet()))
                .thenReturn(new ArrayList<>());

        // Mock 获取经销商信息
        TEfDealerRoster extraInfo = new TEfDealerRoster();
        extraInfo.setFkDealer("DEALER001");
        extraInfo.setMarketingStatus(MarketingStatusEnum.REGISTERED);
        when(efDealerRosterDomainService.getFkDealerAndMarketingStatus(anyString(), anyString()))
                .thenReturn(extraInfo);

        // Mock 批量插入
        when(efDealerRosterDomainService.batchInsert(anyList()))
                .thenReturn(1);

        // Mock 批量同步推荐指标 - 使用简单的RestResult
        when(coreIndexRecommendService.coreIndexRecommendBatchAddOrUpdate(any()))
                .thenReturn(RestResultUtil.success(null));

        // Mock 短信发送
        doNothing().when(smsNoticeSender).sendDealerRosterCreateSmsMessage(anyList());

        int result = strategy.processImport(reqDTO);

        assertEquals(1, result);
    }

    /**
     * 测试processImport方法 - 老链路批量同步指标透传租户
     */
    @Test
    public void processImport_OldPath_TenantPassThrough_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        mockNewDealerImportDependencies();
        when(coreIndexRecommendService.coreIndexRecommendBatchAddOrUpdate(any()))
                .thenReturn(RestResultUtil.success(null));

        strategy.processImport(reqDTO);

        ArgumentCaptor<CoreIndexRecommendBatchAddOrUpdateReqDTO> captor =
                ArgumentCaptor.forClass(CoreIndexRecommendBatchAddOrUpdateReqDTO.class);
        verify(coreIndexRecommendService).coreIndexRecommendBatchAddOrUpdate(captor.capture());
        assertEquals("SYZH000001", captor.getValue().getZoneTenantCode());
        assertEquals("商银微芯", captor.getValue().getZoneTenantName());
    }

    /**
     * 测试processImport方法 - 新链路批量同步指标透传租户
     */
    @Test
    public void processImport_NewPath_TenantPassThrough_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();
        mockNewDealerImportDependencies();

        DynamicConfigSwitchRespDTO switchRespDTO = new DynamicConfigSwitchRespDTO();
        switchRespDTO.setEnabled(true);
        when(dynamicConfigSwitchClient.querySwitch(any()))
                .thenReturn(RestResultUtil.success(switchRespDTO));
        when(indexRecommendClient.batchUpsertIndexRecommend(any()))
                .thenReturn(RestResultUtil.success(null));

        strategy.processImport(reqDTO);

        ArgumentCaptor<IndexRecommendBatchUpsertReqDTO> captor =
                ArgumentCaptor.forClass(IndexRecommendBatchUpsertReqDTO.class);
        verify(indexRecommendClient).batchUpsertIndexRecommend(captor.capture());
        assertEquals("SYZH000001", captor.getValue().getZoneTenantCode());
        assertEquals("商银微芯", captor.getValue().getZoneTenantName());
    }

    /**
     * 测试processImport方法 - 全部更新经销商
     */
    @Test
    public void processImport_AllUpdate_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();

        // Mock 查询已存在经销商名单
        TEfDealerRoster existingRoster = new TEfDealerRoster();
        existingRoster.setPkEfRoster("ROSTER001");
        existingRoster.setCorpNameDealer("经销商1");
        existingRoster.setFkDealer("DEALER001");
        when(efDealerRosterDomainService.queryDealerRosterByFixedNameSet(anyString(), anyString(), any(BankCategoryEnum.class), anySet()))
                .thenReturn(Arrays.asList(existingRoster));

        // Mock 获取经销商信息
        TEfDealerRoster extraInfo = new TEfDealerRoster();
        extraInfo.setFkDealer("DEALER001");
        extraInfo.setMarketingStatus(MarketingStatusEnum.REGISTERED);
        when(efDealerRosterDomainService.getFkDealerAndMarketingStatus(anyString(), anyString()))
                .thenReturn(extraInfo);

        // Mock 批量更新
        when(efDealerRosterDomainService.batchUpdate(anyList()))
                .thenReturn(1);

        // Mock 批量同步推荐指标
        when(coreIndexRecommendService.coreIndexRecommendBatchAddOrUpdate(any()))
                .thenReturn(RestResultUtil.success(null));

        int result = strategy.processImport(reqDTO);

        assertEquals(1, result);
    }

    /**
     * 测试processImport方法 - 新建和更新混合
     */
    @Test
    public void processImport_MixNewAndUpdate_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setFkCorpCore("CORE001");
        reqDTO.setCorpNameCore("核心企业");
        reqDTO.setBankCode(BankCategoryEnum.HENGFENG);
        reqDTO.setDataSource(RosterDataSourceEnum.CORP_CORE);
        reqDTO.setCurrentUserId("user001");
        reqDTO.setCurrentUserName("用户");

        List<RosterImportData> rosterDatas = new ArrayList<>();
        // 第一条：已存在
        RosterImportData data1 = new RosterImportData();
        data1.setCorpNameDealer("经销商1");
        data1.setContactName("联系人1");
        data1.setMobilePhone("13800138001");
        data1.setRowNum(2);
        data1.setMetricsImportData(buildValidMetricsImportDTO());
        rosterDatas.add(data1);

        // 第二条：新建
        RosterImportData data2 = new RosterImportData();
        data2.setCorpNameDealer("经销商2");
        data2.setContactName("联系人2");
        data2.setMobilePhone("13800138002");
        data2.setRowNum(3);
        data2.setMetricsImportData(buildValidMetricsImportDTO());
        rosterDatas.add(data2);

        reqDTO.setRosterDatas(rosterDatas);

        // Mock 查询已存在经销商名单（只有经销商1）
        TEfDealerRoster existingRoster = new TEfDealerRoster();
        existingRoster.setPkEfRoster("ROSTER001");
        existingRoster.setCorpNameDealer("经销商1");
        existingRoster.setFkDealer("DEALER001");
        when(efDealerRosterDomainService.queryDealerRosterByFixedNameSet(anyString(), anyString(), any(BankCategoryEnum.class), anySet()))
                .thenReturn(Arrays.asList(existingRoster));

        // Mock 获取经销商信息
        TEfDealerRoster extraInfo = new TEfDealerRoster();
        extraInfo.setFkDealer("DEALER001");
        extraInfo.setMarketingStatus(MarketingStatusEnum.REGISTERED);
        when(efDealerRosterDomainService.getFkDealerAndMarketingStatus(anyString(), anyString()))
                .thenReturn(extraInfo);

        // Mock 批量插入和更新
        when(efDealerRosterDomainService.batchInsert(anyList()))
                .thenReturn(1);
        when(efDealerRosterDomainService.batchUpdate(anyList()))
                .thenReturn(1);

        // Mock 批量同步推荐指标
        when(coreIndexRecommendService.coreIndexRecommendBatchAddOrUpdate(any()))
                .thenReturn(RestResultUtil.success(null));

        // Mock 短信发送
        doNothing().when(smsNoticeSender).sendDealerRosterCreateSmsMessage(anyList());

        int result = strategy.processImport(reqDTO);

        assertEquals(2, result);
    }

    /**
     * 测试processImport方法 - extraInfo为空抛出异常
     */
    @Test(expected = CcbscfBizException.class)
    public void processImport_ExtraInfoNull_byAI() throws Exception {
        EfDealerRosterImportReqDTO reqDTO = buildValidImportReqDTO();

        // Mock 查询已存在经销商名单为空
        when(efDealerRosterDomainService.queryDealerRosterByFixedNameSet(anyString(), anyString(), any(BankCategoryEnum.class), anySet()))
                .thenReturn(new ArrayList<>());

        // Mock 获取经销商信息为空
        when(efDealerRosterDomainService.getFkDealerAndMarketingStatus(anyString(), anyString()))
                .thenReturn(null);

        strategy.processImport(reqDTO);
    }

    // ==================== getType 方法测试 ====================

    /**
     * 测试getType方法 - 返回HENGFENG
     */
    @Test
    public void getType_ReturnHENGFENG_byAI() throws Exception {
        String type = strategy.getType();
        assertEquals(BankCategoryEnum.HENGFENG.getCode(), type);
    }

    // ==================== 辅助方法 ====================

    /**
     * 构建新建经销商导入的公共Mock
     */
    private void mockNewDealerImportDependencies() {
        when(efDealerRosterDomainService.queryDealerRosterByFixedNameSet(anyString(), anyString(), any(BankCategoryEnum.class), anySet()))
                .thenReturn(new ArrayList<>());

        TEfDealerRoster extraInfo = new TEfDealerRoster();
        extraInfo.setFkDealer("DEALER001");
        extraInfo.setMarketingStatus(MarketingStatusEnum.REGISTERED);
        when(efDealerRosterDomainService.getFkDealerAndMarketingStatus(anyString(), anyString()))
                .thenReturn(extraInfo);

        when(efDealerRosterDomainService.batchInsert(anyList()))
                .thenReturn(1);
        doNothing().when(smsNoticeSender).sendDealerRosterCreateSmsMessage(anyList());
    }

    /**
     * 构建有效的导入请求
     */
    private EfDealerRosterImportReqDTO buildValidImportReqDTO() {
        EfDealerRosterImportReqDTO reqDTO = new EfDealerRosterImportReqDTO();
        reqDTO.setFkCorpCore("CORE001");
        reqDTO.setCorpNameCore("核心企业");
        reqDTO.setBankCode(BankCategoryEnum.HENGFENG);
        reqDTO.setDataSource(RosterDataSourceEnum.CORP_CORE);
        reqDTO.setCurrentUserId("user001");
        reqDTO.setCurrentUserName("用户");
        reqDTO.setZoneTenantCode("SYZH000001");
        reqDTO.setZoneTenantName("商银微芯");

        List<RosterImportData> rosterDatas = new ArrayList<>();
        RosterImportData data = new RosterImportData();
        data.setCorpNameDealer("经销商1");
        data.setContactName("联系人");
        data.setMobilePhone("13800138000");
        data.setRowNum(2);
        data.setMetricsImportData(buildValidMetricsImportDTO());
        rosterDatas.add(data);
        reqDTO.setRosterDatas(rosterDatas);

        return reqDTO;
    }

    /**
     * 构建有效的推荐指标导入DTO
     */
    private EfDealerMetricsImportDTO buildValidMetricsImportDTO() {
        EfDealerMetricsImportDTO metrics = new EfDealerMetricsImportDTO();
        metrics.setMetricsYear("2024");
        metrics.setCooperationPeriod("3年（含）以上");
        metrics.setTierOneDealerFlag("是");
        metrics.setDealerLevel("S1普通级经销商");
        metrics.setCoreRecommendedLimit("10000");
        metrics.setCurrentYearTaskAmount("5000");
        metrics.setLastYearPurchaseAmount("8000");
        metrics.setLastYearCoreSalesRatio("80");
        return metrics;
    }

    }