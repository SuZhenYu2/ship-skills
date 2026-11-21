package com.cbmc.remote.biz.product.constants;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

public class PrincipalCompareModeEnumTest {

    @Test
    public void valueOfCode_shouldReturnMatchingMode() {
        assertEquals(PrincipalCompareModeEnum.PRINCIPAL,
            PrincipalCompareModeEnum.valueOfCode("PRINCIPAL"));
        assertEquals(PrincipalCompareModeEnum.PRINCIPAL_INTEREST,
            PrincipalCompareModeEnum.valueOfCode("PRINCIPAL_INTEREST"));
    }

    @Test
    public void valueOfCode_shouldReturnNullForBlankOrUnknownCode() {
        assertNull(PrincipalCompareModeEnum.valueOfCode(null));
        assertNull(PrincipalCompareModeEnum.valueOfCode(""));
        assertNull(PrincipalCompareModeEnum.valueOfCode("INVALID"));
    }

    @Test
    public void enum_shouldContainOnlyTwoBusinessModes() {
        PrincipalCompareModeEnum[] values = PrincipalCompareModeEnum.values();

        assertEquals(2, values.length);
        assertEquals("PRINCIPAL", values[0].getCode());
        assertEquals("PRINCIPAL_INTEREST", values[1].getCode());
    }
}
