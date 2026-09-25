#include "CSystemMonitor.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

// Estas interfaces de leitura do SMC/HID não têm contrato público de estabilidade.
// Falhas são tratadas como sensor indisponível; nunca se escreve no controlador.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCLimits;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCLimits limits;
    SMCInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMCRequest;

typedef struct { uint32_t key, type, size; } CachedSMCKey;
static CachedSMCKey smc_keys[256];
static int smc_key_count = 0;
static bool smc_discovered = false;
static pthread_mutex_t sensor_mutex = PTHREAD_MUTEX_INITIALIZER;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16)
        | ((uint32_t)(uint8_t)s[2] << 8) | (uint8_t)s[3];
}

static bool smc_call(io_connect_t connection, SMCRequest *input, SMCRequest *output) {
    size_t size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    return IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size) == KERN_SUCCESS
        && size >= sizeof(*output) && output->result == 0;
}

static io_connect_t smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : 0;
}

static bool smc_info(io_connect_t connection, uint32_t key, SMCInfo *info) {
    SMCRequest input = {0}, output = {0};
    input.key = key;
    input.command = 9;
    if (!smc_call(connection, &input, &output)) return false;
    *info = output.info;
    return true;
}

static bool smc_bytes(io_connect_t connection, CachedSMCKey key, uint8_t bytes[32]) {
    SMCRequest input = {0}, output = {0};
    input.key = key.key;
    input.command = 5;
    input.info.size = key.size;
    if (!smc_call(connection, &input, &output)) return false;
    memcpy(bytes, output.bytes, sizeof(output.bytes));
    return true;
}

static bool decode_temperature(CachedSMCKey key, const uint8_t bytes[32], double *value) {
    if (key.size == 2 && key.type == fourcc("sp78")) {
        int16_t raw = (int16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
        *value = (double)raw / 256.0;
    } else if (key.size == 4 && (key.type == fourcc("flt ") || key.type == fourcc("ioft"))) {
        float number;
        memcpy(&number, bytes, sizeof(number));
        *value = number;
    } else {
        return false;
    }
    return isfinite(*value) && *value >= 5 && *value <= 130;
}

static void discover_smc(io_connect_t connection) {
    if (smc_discovered) return;
    SMCInfo count_info = {0};
    if (!smc_info(connection, fourcc("#KEY"), &count_info) || count_info.size != 4) return;
    uint8_t data[32] = {0};
    if (!smc_bytes(connection, (CachedSMCKey){fourcc("#KEY"), count_info.type, 4}, data)) return;
    uint32_t count = ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16)
        | ((uint32_t)data[2] << 8) | data[3];
    if (count > 10000) return;
    smc_discovered = true;
    for (uint32_t index = 0; index < count && smc_key_count < 256; ++index) {
        SMCRequest input = {0}, output = {0};
        input.command = 8;
        input.index = index;
        if (!smc_call(connection, &input, &output)) continue;
        uint32_t key = output.key;
        if ((key >> 24) != 'T') continue;
        SMCInfo info = {0};
        if (!smc_info(connection, key, &info)) continue;
        if (!((info.type == fourcc("sp78") && info.size == 2)
            || ((info.type == fourcc("flt ") || info.type == fourcc("ioft")) && info.size == 4))) continue;
        smc_keys[smc_key_count++] = (CachedSMCKey){key, info.type, info.size};
    }
}

static int append_smc(MSTemperatureSample *buffer, int capacity, int count) {
    io_connect_t connection = smc_open();
    if (!connection) return count;
    discover_smc(connection);
    for (int i = 0; i < smc_key_count && count < capacity; ++i) {
        uint8_t data[32] = {0};
        double value;
        if (!smc_bytes(connection, smc_keys[i], data) || !decode_temperature(smc_keys[i], data, &value)) continue;
        uint32_t key = smc_keys[i].key;
        MSTemperatureSample *sample = &buffer[count++];
        snprintf(sample->identifier, sizeof(sample->identifier), "SMC:%c%c%c%c",
                 (char)(key >> 24), (char)(key >> 16), (char)(key >> 8), (char)key);
        sample->celsius = value;
        sample->source = 1;
    }
    IOServiceClose(connection);
    return count;
}

static int append_battery(MSTemperatureSample *buffer, int capacity, int count) {
    if (count >= capacity) return count;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"));
    if (!service) return count;
    CFTypeRef data = IORegistryEntryCreateCFProperty(service, CFSTR("BatteryData"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    if (!data) return count;
    if (CFGetTypeID(data) == CFDictionaryGetTypeID()) {
        CFTypeRef raw = CFDictionaryGetValue((CFDictionaryRef)data, CFSTR("Temperature"));
        int temperature = 0;
        if (raw && CFGetTypeID(raw) == CFNumberGetTypeID()
            && CFNumberGetValue((CFNumberRef)raw, kCFNumberIntType, &temperature)) {
            double value = (double)temperature / 100.0; // BatteryData: centésimos de °C neste controlador.
            if (value >= -20 && value <= 100) {
                MSTemperatureSample *sample = &buffer[count++];
                strcpy(sample->identifier, "Battery:Pack");
                sample->celsius = value;
                sample->source = 3;
            }
        }
    }
    CFRelease(data);
    return count;
}

typedef void *(*HIDCreate)(CFAllocatorRef);
typedef void (*HIDSetMatching)(void *, CFDictionaryRef);
typedef CFArrayRef (*HIDCopyServices)(void *);
typedef CFTypeRef (*HIDCopyProperty)(void *, CFStringRef);
typedef void *(*HIDCopyEvent)(void *, int64_t, int32_t, int64_t);
typedef double (*HIDGetFloat)(void *, uint32_t);

static int append_hid(MSTemperatureSample *buffer, int capacity, int count) {
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!library) return count;
    HIDCreate create = (HIDCreate)dlsym(library, "IOHIDEventSystemClientCreate");
    HIDSetMatching match = (HIDSetMatching)dlsym(library, "IOHIDEventSystemClientSetMatching");
    HIDCopyServices services = (HIDCopyServices)dlsym(library, "IOHIDEventSystemClientCopyServices");
    HIDCopyProperty property = (HIDCopyProperty)dlsym(library, "IOHIDServiceClientCopyProperty");
    HIDCopyEvent event = (HIDCopyEvent)dlsym(library, "IOHIDServiceClientCopyEvent");
    HIDGetFloat get_float = (HIDGetFloat)dlsym(library, "IOHIDEventGetFloatValue");
    if (!create || !match || !services || !property || !event || !get_float) { dlclose(library); return count; }
    void *client = create(kCFAllocatorDefault);
    if (!client) { dlclose(library); return count; }
    int page = 0xff00, usage = 5;
    CFNumberRef page_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usage_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {page_number, usage_number};
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                   &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    match(client, matching);
    CFRelease(matching);
    CFRelease(page_number);
    CFRelease(usage_number);
    CFArrayRef found = services(client);
    if (found) {
        for (CFIndex i = 0; i < CFArrayGetCount(found) && count < capacity; ++i) {
            void *service = (void *)CFArrayGetValueAtIndex(found, i);
            CFTypeRef name = property(service, CFSTR("Product"));
            void *reading = event(service, 15, 0, 0);
            if (name && CFGetTypeID(name) == CFStringGetTypeID() && reading) {
                double value = get_float(reading, 15 << 16);
                char label[48] = {0};
                if (isfinite(value) && value >= -20 && value <= 130
                    && CFStringGetCString((CFStringRef)name, label, sizeof(label), kCFStringEncodingUTF8)) {
                    MSTemperatureSample *sample = &buffer[count++];
                    snprintf(sample->identifier, sizeof(sample->identifier), "HID:%s", label);
                    int duplicate = 1;
                    for (int j = 0; j < count - 1; ++j) {
                        if (strncmp(buffer[j].identifier, sample->identifier, sizeof(sample->identifier)) == 0
                            || (strncmp(buffer[j].identifier, sample->identifier, strlen(sample->identifier)) == 0
                                && buffer[j].identifier[strlen(sample->identifier)] == '#')) duplicate++;
                    }
                    if (duplicate > 1) {
                        snprintf(sample->identifier, sizeof(sample->identifier), "HID:%.48s#%d", label, duplicate);
                    }
                    sample->celsius = value;
                    sample->source = 2;
                }
            }
            if (reading) CFRelease(reading);
            if (name) CFRelease(name);
        }
        CFRelease(found);
    }
    CFRelease(client);
    dlclose(library);
    return count;
}

int32_t ms_read_temperatures(MSTemperatureSample *buffer, int32_t capacity) {
    if (!buffer || capacity <= 0) return 0;
    pthread_mutex_lock(&sensor_mutex);
    int count = append_smc(buffer, capacity, 0);
    count = append_battery(buffer, capacity, count);
    count = append_hid(buffer, capacity, count);
    pthread_mutex_unlock(&sensor_mutex);
    return count;
}
