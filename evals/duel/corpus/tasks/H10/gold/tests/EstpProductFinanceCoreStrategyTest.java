package com.ccbscf.api.web.product.handler.core.impl;

import com.ccbscf.api.web.product.model.ProductCoreCashFlowVO;
import com.ccbscf.biz.ci.constants.BankCategoryEnum;
import com.ccbscf.biz.product.constants.FinanceProductTypeEnum;
import com.ccbscf.common.constants.OperationCodeEnum;
import com.ccbscf.common.exception.CcbscfBizException;
import com.ccbscf.common.web.model.RestResult;
import com.ccbscf.remote.biz.ci.client.FinanceService;
import com.ccbscf.remote.biz.ci.model.TCiFinance;
import com.ccbscf.remote.biz.product.constants.ProductCommonConstants;
import com.ccbscf.remote.biz.product.constants.SelfInterestTypeEnum;
import org.apache.commons.lang3.StringUtils;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * EstpProductFinanceCoreStrategy 单元测试
 *
 * 重点覆盖 e收 新增的【息费承担方范围】(interestPayer) 校验逻辑：
 * - 展示集合（NO_SPECIAL / INTEREST_FEE_SEPARATE）内：必填 + 值域校验
 * - 展示集合外（含 enableSelfInterest=false）：传入即报错（不再静默清空）
 */
@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class EstpProductFinanceCoreStrategyTest {

    @Mock
    private FinanceService financeService;

    @InjectMocks
    private EstpProductFinanceCoreStrategy strategy;

    private ProductCoreCashFlowVO vo;
    private TCiFinance ciFinance;

    @BeforeEach
    void setUp() {
        vo = createBaseVO();
        ciFinance = createBaseCiFinance();
        setupFinanceServiceMock();
    }

    /**
     * 创建基础 VO 对象，包含所有必要字段
     */
    private ProductCoreCashFlowVO createBaseVO() {
        ProductCoreCashFlowVO vo = new ProductCoreCashFlowVO();
        vo.setFkCore("test-core-id-12345678901234567890123456");
        vo.setCorpNameCore("测试核心企业");
        vo.setFkFinance("test-finance-id-1234567890123456789012");
        vo.setCoreShortname("核心简称");
        vo.setProductType(FinanceProductTypeEnum.FACTORING_WITHOUT_RESOURCE_ESTP);
        vo.setenableSelfInterest(true);
        vo.setSelfInterestType(SelfInterestTypeEnum.NO_SPECIAL.getCode());
        vo.setInterestPayer("CORE,CORP");
        // e收 必传：是否为供应商生成确权申请回执
        vo.setEnableGenerateIssueReceiptForSupplier(ProductCommonConstants.Y);
        return vo;
    }

    /**
     * 创建基础金融机构对象（使用非中信/非工行 行别，避免进入其它分支）
     */
    private TCiFinance createBaseCiFinance() {
        TCiFinance finance = new TCiFinance();
        finance.setBankCategory(BankCategoryEnum.CCB);
        return finance;
    }

    /**
     * 设置 FinanceService mock
     */
    private void setupFinanceServiceMock() {
        RestResult<TCiFinance> result = mock(RestResult.class);
        when(result.tryResult()).thenReturn(ciFinance);
        when(financeService.findFinance(anyString())).thenReturn(result);
    }

    // ========== getProductType 测试 ==========

    @Test
    @DisplayName("getProductType 应返回 FACTORING_WITHOUT_RESOURCE_ESTP")
    void getProductType_shouldReturnEstp() {
        assertEquals(FinanceProductTypeEnum.FACTORING_WITHOUT_RESOURCE_ESTP, strategy.getProductType());
    }

    // ========== fillDataInfo 测试（正式表 / 临时表两个重载） ==========

    @Test
    @DisplayName("fillDataInfo(DTO) - 应填充审批表详情信息")
    void fillDataInfo_withDto_shouldFillApproveFormInfo() {
        com.ccbscf.remote.biz.product.model.TProductCashFlowDTO dto =
                new com.ccbscf.remote.biz.product.model.TProductCashFlowDTO();
        ProductCoreCashFlowVO.ApproveFormInfo approveFormInfo = new ProductCoreCashFlowVO.ApproveFormInfo();
        approveFormInfo.setCustomerNo("customer-no-001");
        vo.setApproveFormInfo(approveFormInfo);
        strategy.fillDataInfo(vo, dto);
        assertTrue(dto.getApproveFormDTO() != null);
        assertEquals("customer-no-001", dto.getApproveFormDTO().getCustomerNo());
    }

    @Test
    @DisplayName("fillDataInfo(TDTO) - 应填充审批表详情信息")
    void fillDataInfo_withTempDto_shouldFillApproveFormInfo() {
        com.ccbscf.remote.biz.product.model.TProductCashFlowTDTO dto =
                new com.ccbscf.remote.biz.product.model.TProductCashFlowTDTO();
        ProductCoreCashFlowVO.ApproveFormInfo approveFormInfo = new ProductCoreCashFlowVO.ApproveFormInfo();
        approveFormInfo.setCustomerNo("customer-no-002");
        vo.setApproveFormInfo(approveFormInfo);
        strategy.fillDataInfo(vo, dto);
        assertTrue(dto.getApproveFormDTO() != null);
        assertEquals("customer-no-002", dto.getApproveFormDTO().getCustomerNo());
    }

    // ========== 息费承担方范围 校验测试 ==========

    @Nested
    @DisplayName("息费承担方范围校验测试")
    class ValidInterestPayerScopeTests {

        @Test
        @DisplayName("模式=无特殊自定义类型 + 范围=签发方,融资方 - 校验通过")
        void withNoSpecialAndCoreCorp_shouldPass() {
            vo.setInterestPayer("CORE,CORP");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertEquals("CORE,CORP", vo.getInterestPayer());
        }

        @Test
        @DisplayName("模式=无特殊自定义类型 + 范围为空 - 应抛出异常")
        void withNoSpecialAndBlankPayer_shouldThrowException() {
            vo.setInterestPayer("");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("息费承担方范围"));
        }

        @Test
        @DisplayName("模式=无特殊自定义类型 + 范围为 null - 应抛出异常")
        void withNoSpecialAndNullPayer_shouldThrowException() {
            vo.setInterestPayer(null);
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("息费承担方范围"));
        }

        @Test
        @DisplayName("模式=指定息费分开承担 + 范围=三方 - 校验通过")
        void withInterestFeeSeparateAndAllPayer_shouldPass() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE,CORP,SOURCE");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertEquals("CORE,CORP,SOURCE", vo.getInterestPayer());
        }

        @Test
        @DisplayName("模式=指定息费分开承担 + 范围=额度来源方 - 校验通过")
        void withInterestFeeSeparateAndSource_shouldPass() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("SOURCE");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("模式=指定息费分开承担 + 范围值非法 - 应抛出异常")
        void withInterestFeeSeparateAndInvalidPayer_shouldThrowException() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("INVALID_PAYER");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("未知的息费承担方范围"));
            assertTrue(exception.getMessage().contains("INVALID_PAYER"));
        }

        @Test
        @DisplayName("模式=无特殊自定义类型 + 范围=纯逗号（无有效值） - 应报必填，不得绕过值域校验")
        void withNoSpecialAndOnlySeparators_shouldThrowRequiredException() {
            vo.setInterestPayer(",");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("息费承担方范围"));
        }

        @Test
        @DisplayName("模式=无特殊自定义类型 + 范围=连续逗号 - 应报必填（空项被剔除）")
        void withNoSpecialAndConsecutiveSeparators_shouldThrowRequiredException() {
            vo.setInterestPayer(",,");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("息费承担方范围"));
        }

        @Test
        @DisplayName("模式=无特殊自定义类型 + 范围=逗号后带空格 - 应通过（trim 归一化）")
        void withNoSpecialAndSpaceAfterComma_shouldPass() {
            vo.setInterestPayer("CORE, CORP");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("模式=指定息费分开承担 + 范围=首尾逗号与空格 - 应通过（空项被剔除）")
        void withSeparateAndSurroundingSeparators_shouldPass() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer(" CORE , CORP , SOURCE ");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("模式=指定息费分开承担 + 空格包裹的合法值 - trim 后仍参与值域校验")
        void withSeparateAndBlankOnlyItem_shouldThrowRequiredException() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer(" , ");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("息费承担方范围"));
        }

        @Test
        @DisplayName("模式=自定义付息费比例 - 传入范围应报错（不支持的配置）")
        void withInterestFeeRatioAndPayer_shouldThrow() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_RATIO.getCode());
            vo.setInterestPayer("CORE,CORP");
            CcbscfBizException ex = assertThrows(CcbscfBizException.class,
                    () -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertTrue(ex.getMessage().contains("不支持配置【息费承担方范围】"));
        }

        @Test
        @DisplayName("模式=买卖方差别定价 - 传入范围应报错（不支持的配置）")
        void withDiffPriceAndPayer_shouldThrow() {
            vo.setSelfInterestType(SelfInterestTypeEnum.DIFF_PRICE_BUYERS_SELLERS.getCode());
            vo.setInterestPayer("CORE,CORP");
            CcbscfBizException ex = assertThrows(CcbscfBizException.class,
                    () -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertTrue(ex.getMessage().contains("不支持配置【息费承担方范围】"));
        }

        @Test
        @DisplayName("模式=债务人付息选择缴费单位 - 传入范围应报错（不支持的配置）")
        void withDebtorChoicePaymentUnitAndPayer_shouldThrow() {
            vo.setSelfInterestType(SelfInterestTypeEnum.DEBTOR_CHOICE_PAYMENT_UNIT.getCode());
            vo.setSelfInterestPayUnits("unit1");
            vo.setInterestPayer("CORE,CORP");
            CcbscfBizException ex = assertThrows(CcbscfBizException.class,
                    () -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertTrue(ex.getMessage().contains("不支持配置【息费承担方范围】"));
        }

        @Test
        @DisplayName("模式=自定义付息费比例 - 范围为空则正常通过（不触发报错）")
        void withInterestFeeRatioAndBlankPayer_shouldPass() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_RATIO.getCode());
            vo.setInterestPayer(null);
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("enableSelfInterest=false - 传入范围应报错；模式/缴费单位仍按历史逻辑清空")
        void withDisabledAndPayer_shouldThrow() {
            vo.setenableSelfInterest(false);
            vo.setSelfInterestType(SelfInterestTypeEnum.NO_SPECIAL.getCode());
            vo.setSelfInterestPayUnits("unit1,unit2");
            vo.setInterestPayer("CORE,CORP");
            CcbscfBizException ex = assertThrows(CcbscfBizException.class,
                    () -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertTrue(ex.getMessage().contains("不支持配置【息费承担方范围】"));
            // 历史逻辑：开关关闭时模式/缴费单位仍被清空（本次未改）
            assertEquals("", vo.getSelfInterestType());
            assertEquals("", vo.getSelfInterestPayUnits());
        }

        @Test
        @DisplayName("enableSelfInterest=false - 范围为空则正常通过，不触发必填校验")
        void withDisabledAndBlankPayer_shouldNotThrow() {
            vo.setenableSelfInterest(false);
            vo.setSelfInterestType(SelfInterestTypeEnum.NO_SPECIAL.getCode());
            vo.setInterestPayer(null);
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
            // 不再对该字段做清空，空值保持原样（null 与 "" 对"为空"语义等价）
            assertTrue(StringUtils.isBlank(vo.getInterestPayer()));
        }

        @Test
        @DisplayName("enableSelfInterest=false 且模式为空 - 模式/值域校验均跳过，正常通过")
        void withDisabledAndBlankSelfInterestType_shouldNotThrow() {
            vo.setenableSelfInterest(false);
            vo.setSelfInterestType(null);
            vo.setSelfInterestPayUnits(null);
            vo.setInterestPayer(null);
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
            // 历史逻辑：开关关闭时模式与缴费单位被清空
            assertEquals("", vo.getSelfInterestType());
            assertEquals("", vo.getSelfInterestPayUnits());
        }
    }

    // ========== 民生/广发：签发方与额度来源方 二选一 ==========

    @Nested
    @DisplayName("民生/广发 互斥校验测试")
    class MutexPayerScopeTests {

        @Test
        @DisplayName("民生 + 签发方,融资方 - 校验通过")
        void withCmbcAndCoreCorp_shouldPass() {
            ciFinance.setBankCategory(BankCategoryEnum.CMBC);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE,CORP");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("民生 + 额度来源方,融资方 - 校验通过")
        void withCmbcAndSourceCorp_shouldPass() {
            ciFinance.setBankCategory(BankCategoryEnum.CMBC);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("SOURCE,CORP");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("民生 + 签发方与额度来源方同时勾选 - 应抛出异常")
        void withCmbcAndCoreAndSource_shouldThrowException() {
            ciFinance.setBankCategory(BankCategoryEnum.CMBC);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE,SOURCE");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("签发方与额度来源方不可同时勾选"));
        }

        @Test
        @DisplayName("民生 + 三方全选 - 应抛出异常")
        void withCmbcAndAllThree_shouldThrowException() {
            ciFinance.setBankCategory(BankCategoryEnum.CMBC);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE,CORP,SOURCE");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("签发方与额度来源方不可同时勾选"));
        }

        @Test
        @DisplayName("广发 + 签发方与额度来源方同时勾选 - 应抛出异常")
        void withGdbAndCoreAndSource_shouldThrowException() {
            ciFinance.setBankCategory(BankCategoryEnum.GDB);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE,SOURCE");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("签发方与额度来源方不可同时勾选"));
        }

        @Test
        @DisplayName("广发 + 签发方,融资方 - 校验通过")
        void withGdbAndCoreCorp_shouldPass() {
            ciFinance.setBankCategory(BankCategoryEnum.GDB);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE,CORP");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("非民生非广发 + 签发方与额度来源方同时勾选 - 不校验，通过")
        void withOtherBankAndCoreAndSource_shouldPass() {
            ciFinance.setBankCategory(BankCategoryEnum.CCB);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE,SOURCE");
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
        }

        @Test
        @DisplayName("民生 + 带空格的签发方与额度来源方 - trim 后仍应命中互斥")
        void withCmbcAndSpacedCoreAndSource_shouldThrowException() {
            ciFinance.setBankCategory(BankCategoryEnum.CMBC);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer("CORE, SOURCE");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("签发方与额度来源方不可同时勾选"));
        }
    }

    // ========== 上下级一致性：模式与范围联动 ==========

    @Nested
    @DisplayName("上下级一致性（上级不支持则传入报错）测试")
    class InterestPayerConsistencyTests {

        @Test
        @DisplayName("无特殊自定义类型 + 空范围 - 必传报错（露出的分支）")
        void withNoSpecialAndBlank_shouldThrow() {
            vo.setSelfInterestType(SelfInterestTypeEnum.NO_SPECIAL.getCode());
            vo.setInterestPayer(null);
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("息费承担方范围"));
        }

        @Test
        @DisplayName("指定息费分开承担 + 空范围 - 必传报错")
        void withSeparateAndBlank_shouldThrow() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setInterestPayer(null);
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("息费承担方范围"));
        }

        @Test
        @DisplayName("自定义付息费比例 + 传入非法范围值 - 报错（上级不支持该参数，先于值域校验）")
        void withRatioAndInvalidValue_shouldThrow() {
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_RATIO.getCode());
            vo.setInterestPayer("CORE,INVALID");
            CcbscfBizException ex = assertThrows(CcbscfBizException.class,
                    () -> strategy.check(vo, OperationCodeEnum.CREATE));
            // 报的是"不支持配置"，而不是"未知的范围值"——上级判定优先于值域校验
            assertTrue(ex.getMessage().contains("不支持配置【息费承担方范围】"));
        }

        @Test
        @DisplayName("买卖方差别定价 + 传入范围值 - 报错")
        void withDiffPriceAndValue_shouldThrow() {
            vo.setSelfInterestType(SelfInterestTypeEnum.DIFF_PRICE_BUYERS_SELLERS.getCode());
            vo.setInterestPayer("CORE,SOURCE");
            CcbscfBizException ex = assertThrows(CcbscfBizException.class,
                    () -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertTrue(ex.getMessage().contains("不支持配置【息费承担方范围】"));
        }

        @Test
        @DisplayName("签发自定义息费承担方=否 + 传入模式与范围 - 报错（历史清空仍生效于模式/缴费单位）")
        void withDisabledAndAllValues_shouldThrow() {
            vo.setenableSelfInterest(false);
            vo.setSelfInterestType(SelfInterestTypeEnum.INTEREST_FEE_SEPARATE.getCode());
            vo.setSelfInterestPayUnits("unit1");
            vo.setInterestPayer("CORE,SOURCE");
            CcbscfBizException ex = assertThrows(CcbscfBizException.class,
                    () -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertTrue(ex.getMessage().contains("不支持配置【息费承担方范围】"));
            assertEquals("", vo.getSelfInterestType());
            assertEquals("", vo.getSelfInterestPayUnits());
        }
    }

    // ========== 回归：现有逻辑未被破坏 ==========

    @Nested
    @DisplayName("现有 e收 逻辑回归测试")
    class ExistingLogicRegressionTests {

        @Test
        @DisplayName("模式=债务人付息选择缴费单位 + 缴费单位为空 - 应抛出异常（历史逻辑）")
        void withDebtorChoiceAndBlankPayUnits_shouldThrowException() {
            vo.setSelfInterestType(SelfInterestTypeEnum.DEBTOR_CHOICE_PAYMENT_UNIT.getCode());
            vo.setSelfInterestPayUnits(null);
            vo.setInterestPayer(null);
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("缴费单位"));
        }

        @Test
        @DisplayName("模式=债务人付息选择缴费单位 + 缴费单位为空串 - 应抛出异常（历史逻辑）")
        void withDebtorChoiceAndEmptyPayUnits_shouldThrowException() {
            vo.setSelfInterestType(SelfInterestTypeEnum.DEBTOR_CHOICE_PAYMENT_UNIT.getCode());
            vo.setSelfInterestPayUnits("");
            vo.setInterestPayer(null);
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("缴费单位"));
        }


        @Test
        @DisplayName("非建行 - 是否生成确权申请回执 应被强制置为 N")
        void withNonCcbBank_shouldForceReceiptFlagToN() {
            // 基线 fixture 为建行(CCB)，此处显式改为非建行以触发强制置 N
            ciFinance.setBankCategory(BankCategoryEnum.CITIC);
            vo.setEnableGenerateIssueReceiptForSupplier(ProductCommonConstants.Y);
            vo.setFkAccount("test-account-000000000000000000000000");
            vo.setRepaymentType(ProductCommonConstants.REPAYMENT_TYPE_LIST.get(0));
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertEquals(ProductCommonConstants.N, vo.getEnableGenerateIssueReceiptForSupplier());
        }

        @Test
        @DisplayName("建行 - 是否生成确权申请回执 保持原值 Y")
        void withCcbBank_shouldKeepReceiptFlag() {
            ciFinance.setBankCategory(BankCategoryEnum.CCB);
            vo.setEnableGenerateIssueReceiptForSupplier(ProductCommonConstants.Y);
            assertDoesNotThrow(() -> strategy.check(vo, OperationCodeEnum.CREATE));
            assertEquals(ProductCommonConstants.Y, vo.getEnableGenerateIssueReceiptForSupplier());
        }

        @Test
        @DisplayName("中信行别 + 金融机构收款账户为空 - 应抛出异常（历史逻辑）")
        void withCiticAndBlankFkAccount_shouldThrowException() {
            ciFinance.setBankCategory(BankCategoryEnum.CITIC);
            vo.setFkAccount(null);
            vo.setRepaymentType(ProductCommonConstants.REPAYMENT_TYPE_LIST.get(0));
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("金融机构收款账户"));
        }

        @Test
        @DisplayName("中信行别 + 还款方式为空 - 应抛出异常（历史逻辑）")
        void withCiticAndBlankRepaymentType_shouldThrowException() {
            ciFinance.setBankCategory(BankCategoryEnum.CITIC);
            vo.setFkAccount("test-account-000000000000000000000000");
            vo.setRepaymentType(null);
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("还款方式"));
        }

        @Test
        @DisplayName("中信行别 + 还款方式非法值 - 应抛出异常（历史逻辑）")
        void withCiticAndInvalidRepaymentType_shouldThrowException() {
            ciFinance.setBankCategory(BankCategoryEnum.CITIC);
            vo.setFkAccount("test-account-000000000000000000000000");
            vo.setRepaymentType("INVALID_REPAYMENT_TYPE");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("未知的还款方式"));
        }

        @Test
        @DisplayName("开启自定义息费但模式为空 - 应抛出异常")
        void withEnabledAndBlankSelfInterestType_shouldThrowException() {
            vo.setenableSelfInterest(true);
            vo.setSelfInterestType("");
            vo.setInterestPayer("CORE,CORP");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("自定义息费方式类型"));
        }

        @Test
        @DisplayName("模式值非法 - 应抛出异常")
        void withInvalidSelfInterestType_shouldThrowException() {
            vo.setenableSelfInterest(true);
            vo.setSelfInterestType("UNKNOWN_TYPE");
            vo.setInterestPayer("CORE,CORP");
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("自定义息费方式类型不合法"));
        }

        @Test
        @DisplayName("供应商确权申请回执为空 - 应抛出异常")
        void withBlankReceiptFlag_shouldThrowException() {
            vo.setEnableGenerateIssueReceiptForSupplier(null);
            CcbscfBizException exception = assertThrows(
                CcbscfBizException.class,
                () -> strategy.check(vo, OperationCodeEnum.CREATE)
            );
            assertTrue(exception.getMessage().contains("是否为供应商生成确权申请回执"));
        }
    }
}
