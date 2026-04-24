// SPDX-License-Identifier: GPL
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/hwmon.h>
#include <linux/platform_device.h>
#include <linux/mutex.h>

#define DRIVER_NAME "zettlab_d8_fans"

// MMIO
#define FAN_BASE_ADDR 0xFE0B0456
#define FAN_REG_SIZE  0x10

// Offsets
#define FAN1_RPM_OFFSET 0
#define FAN1_PWM_OFFSET 2
#define FAN2_RPM_OFFSET 3
#define FAN2_PWM_OFFSET 5
#define FAN3_RPM_OFFSET 6
#define FAN3_PWM_OFFSET 8

#define PWM_MAX_HW 0xB7

struct zettlab_data {
    void __iomem *base;
    struct mutex lock;
    u8 pwm_enable[3]; // 1 = manual, 2 = auto (fan3 only)
};

/* ================= MMIO ================= */

static u16 zettlab_read_rpm(struct zettlab_data *data, u8 offset)
{
    u8 hi = ioread8(data->base + offset);
    u8 lo = ioread8(data->base + offset + 1);
    return (hi << 8) | lo;
}

static u8 zettlab_read_pwm(struct zettlab_data *data, u8 offset)
{
    return ioread8(data->base + offset);
}

static void zettlab_write_pwm(struct zettlab_data *data, u8 offset, u8 val)
{
    iowrite8(val, data->base + offset);
}

/* ================= Visibility ================= */

static umode_t zettlab_is_visible(const void *drvdata,
                                  enum hwmon_sensor_types type,
                                  u32 attr, int channel)
{
    switch (type) {
    case hwmon_fan:
        switch (attr) {
        case hwmon_fan_input:
        case hwmon_fan_label:
            return 0444;
        default:
            return 0;
        }

    case hwmon_pwm:
        switch (attr) {
        case hwmon_pwm_input:
            return 0644;
        case hwmon_pwm_enable:
            /* only fan3 supports auto */
            return (channel == 2) ? 0644 : 0444;
        default:
            return 0;
        }

    default:
        return 0;
    }
}

/* ================= Read ================= */

static int zettlab_read(struct device *dev,
                        enum hwmon_sensor_types type,
                        u32 attr, int channel, long *val)
{
    struct zettlab_data *data = dev_get_drvdata(dev);

    mutex_lock(&data->lock);

    switch (type) {

    case hwmon_fan:
        if (attr != hwmon_fan_input)
            goto err;

        switch (channel) {
        case 0: *val = zettlab_read_rpm(data, FAN1_RPM_OFFSET); break;
        case 1: *val = zettlab_read_rpm(data, FAN2_RPM_OFFSET); break;
        case 2: *val = zettlab_read_rpm(data, FAN3_RPM_OFFSET); break;
        default: goto err;
        }
        break;

    case hwmon_pwm:
        switch (attr) {

        case hwmon_pwm_input:
            switch (channel) {
            case 0: *val = zettlab_read_pwm(data, FAN1_PWM_OFFSET); break;
            case 1: *val = zettlab_read_pwm(data, FAN2_PWM_OFFSET); break;
            case 2: *val = zettlab_read_pwm(data, FAN3_PWM_OFFSET); break;
            default: goto err;
            }
            break;

        case hwmon_pwm_enable:
            *val = data->pwm_enable[channel];
            break;

        default:
            goto err;
        }
        break;

    default:
        goto err;
    }

    mutex_unlock(&data->lock);
    return 0;

err:
    mutex_unlock(&data->lock);
    return -EOPNOTSUPP;
}

/* ================= Write ================= */

static int zettlab_write(struct device *dev,
                         enum hwmon_sensor_types type,
                         u32 attr, int channel, long val)
{
    struct zettlab_data *data = dev_get_drvdata(dev);
    u8 hw;

    if (type != hwmon_pwm)
        return -EOPNOTSUPP;

    mutex_lock(&data->lock);

    switch (attr) {

    case hwmon_pwm_input:
        if (data->pwm_enable[channel] != 1) {
            mutex_unlock(&data->lock);
            return -EOPNOTSUPP;
        }

        if (val < 0 || val > PWM_MAX_HW) {
            mutex_unlock(&data->lock);
            return -EINVAL;
        }

        hw = val;

        switch (channel) {
        case 0: zettlab_write_pwm(data, FAN1_PWM_OFFSET, hw); break;
        case 1: zettlab_write_pwm(data, FAN2_PWM_OFFSET, hw); break;
        case 2: zettlab_write_pwm(data, FAN3_PWM_OFFSET, hw); break;
        default:
            mutex_unlock(&data->lock);
            return -EINVAL;
        }
        break;

    case hwmon_pwm_enable:

        switch (val) {
        case 1: // manual
            data->pwm_enable[channel] = 1;
            break;

        case 2: // auto (fan3 only)
            if (channel != 2) {
                mutex_unlock(&data->lock);
                return -EOPNOTSUPP;
            }

            data->pwm_enable[channel] = 2;

            // auto mode → PWM = 0
            zettlab_write_pwm(data, FAN3_PWM_OFFSET, 0);
            break;

        default:
            mutex_unlock(&data->lock);
            return -EINVAL;
        }
        break;

    default:
        mutex_unlock(&data->lock);
        return -EOPNOTSUPP;
    }

    mutex_unlock(&data->lock);
    return 0;
}

/* ================= Labels ================= */

static int zettlab_read_string(struct device *dev,
                               enum hwmon_sensor_types type,
                               u32 attr, int channel,
                               const char **str)
{
    if (type != hwmon_fan || attr != hwmon_fan_label)
        return -EOPNOTSUPP;

    switch (channel) {
    case 0: *str = "Disks 1"; break;
    case 1: *str = "Disks 2"; break;
    case 2: *str = "CPU"; break;
    default: return -EINVAL;
    }

    return 0;
}

/* ================= Channel config ================= */

static const struct hwmon_channel_info *zettlab_info[] = {
    HWMON_CHANNEL_INFO(fan,
        HWMON_F_INPUT | HWMON_F_LABEL,
        HWMON_F_INPUT | HWMON_F_LABEL,
        HWMON_F_INPUT | HWMON_F_LABEL),
    HWMON_CHANNEL_INFO(pwm,
        HWMON_PWM_INPUT | HWMON_PWM_ENABLE,
        HWMON_PWM_INPUT | HWMON_PWM_ENABLE,
        HWMON_PWM_INPUT | HWMON_PWM_ENABLE),
    NULL
};

static const struct hwmon_ops zettlab_ops = {
    .is_visible = zettlab_is_visible,
    .read = zettlab_read,
    .write = zettlab_write,
    .read_string = zettlab_read_string,
};

static const struct hwmon_chip_info zettlab_chip_info = {
    .ops = &zettlab_ops,
    .info = zettlab_info,
};

/* ================= Driver ================= */

static int zettlab_probe(struct platform_device *pdev)
{
    struct zettlab_data *data;

    data = devm_kzalloc(&pdev->dev, sizeof(*data), GFP_KERNEL);
    if (!data)
        return -ENOMEM;

    mutex_init(&data->lock);

    data->pwm_enable[0] = 1;
    data->pwm_enable[1] = 1;
    data->pwm_enable[2] = 1;

    data->base = ioremap(FAN_BASE_ADDR, FAN_REG_SIZE);
    if (!data->base)
        return -ENOMEM;

    return PTR_ERR_OR_ZERO(
        devm_hwmon_device_register_with_info(
            &pdev->dev,
            DRIVER_NAME,
            data,
            &zettlab_chip_info,
            NULL
        )
    );
}

static struct platform_driver zettlab_driver = {
    .driver = {
        .name = DRIVER_NAME,
    },
    .probe = zettlab_probe,
};

static struct platform_device *zettlab_pdev;

static int __init zettlab_init(void)
{
    int ret;

    zettlab_pdev = platform_device_register_simple(DRIVER_NAME, -1, NULL, 0);
    if (IS_ERR(zettlab_pdev))
        return PTR_ERR(zettlab_pdev);

    ret = platform_driver_register(&zettlab_driver);
    if (ret)
        platform_device_unregister(zettlab_pdev);

    return ret;
}

static void __exit zettlab_exit(void)
{
    platform_driver_unregister(&zettlab_driver);
    platform_device_unregister(zettlab_pdev);
}

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Dean Holland (speedster@haveacry.com)");
MODULE_DESCRIPTION("Zettlab D8 Ultra AI NAS Fan Driver");

module_init(zettlab_init);
module_exit(zettlab_exit);
