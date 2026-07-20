#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

static const float minimumConfidence = 0.20f;

static NSString *normalize(NSString *text) {
    NSString *lowercase = text.lowercaseString;
    NSRegularExpression *spaces = [NSRegularExpression
        regularExpressionWithPattern:@"\\s+"
        options:0
        error:nil];
    NSString *collapsed = [spaces
        stringByReplacingMatchesInString:lowercase
        options:0
        range:NSMakeRange(0, lowercase.length)
        withTemplate:@" "];
    return [collapsed stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *firstMatch(NSString *pattern, NSString *text, NSUInteger group) {
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive
        error:nil];
    NSTextCheckingResult *match = [expression
        firstMatchInString:text
        options:0
        range:NSMakeRange(0, text.length)];
    if (match == nil || group >= match.numberOfRanges) {
        return nil;
    }
    NSRange range = [match rangeAtIndex:group];
    if (range.location == NSNotFound) {
        return nil;
    }
    return [text substringWithRange:range];
}

static double centerX(NSDictionary *observation) {
    return [observation[@"x"] doubleValue] +
        [observation[@"width"] doubleValue] / 2.0;
}

static double centerY(NSDictionary *observation) {
    return [observation[@"y"] doubleValue] +
        [observation[@"height"] doubleValue] / 2.0;
}

static BOOL containsTokens(NSString *text, NSArray<NSString *> *tokens) {
    for (NSString *token in tokens) {
        if ([text rangeOfString:token].location == NSNotFound) {
            return NO;
        }
    }
    return YES;
}

static NSDictionary *nearestValue(
    NSArray<NSDictionary *> *observations,
    NSArray<NSArray<NSString *> *> *labelTokenSets,
    NSString *valuePattern
) {
    NSMutableArray<NSDictionary *> *labels = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *values = [NSMutableArray array];
    for (NSDictionary *observation in observations) {
        if ([observation[@"confidence"] floatValue] < minimumConfidence) {
            continue;
        }
        NSString *text = normalize(observation[@"text"]);
        for (NSArray<NSString *> *tokens in labelTokenSets) {
            if (containsTokens(text, tokens)) {
                [labels addObject:observation];
                break;
            }
        }
        if (firstMatch(valuePattern, text, 0) != nil) {
            [values addObject:observation];
        }
    }

    NSDictionary *selected = nil;
    double selectedScore = DBL_MAX;
    for (NSDictionary *label in labels) {
        for (NSDictionary *value in values) {
            double horizontal = fabs(centerX(label) - centerX(value));
            double vertical = centerY(value) - centerY(label);
            double directionPenalty = vertical < -0.03 ? 4.0 : 0.0;
            double distancePenalty = fabs(vertical) > 0.30 ? 2.0 : 0.0;
            double score =
                horizontal * 1.5 + fabs(vertical) +
                directionPenalty + distancePenalty;
            if (score < selectedScore) {
                selected = value;
                selectedScore = score;
            }
        }
    }
    return selectedScore < 1.0 ? selected : nil;
}

static NSString *matchedValue(
    NSArray<NSDictionary *> *observations,
    NSArray<NSArray<NSString *> *> *labelTokenSets,
    NSString *pattern,
    NSUInteger group
) {
    NSDictionary *observation = nearestValue(
        observations,
        labelTokenSets,
        pattern);
    if (observation == nil) {
        return nil;
    }
    return firstMatch(pattern, observation[@"text"], group);
}

static NSString *inferTrainingBenefit(
    NSArray<NSDictionary *> *observations
) {
    NSMutableArray<NSDictionary *> *labels = [NSMutableArray array];
    for (NSDictionary *observation in observations) {
        NSString *text = normalize(observation[@"text"]);
        if ([text containsString:@"training"] &&
            [text containsString:@"benefit"]) {
            [labels addObject:observation];
        }
    }

    NSDictionary *selected = nil;
    double selectedScore = DBL_MAX;
    for (NSDictionary *label in labels) {
        for (NSDictionary *candidate in observations) {
            NSString *text = normalize(candidate[@"text"]);
            if ([candidate[@"confidence"] floatValue] < minimumConfidence ||
                text.length < 5 ||
                [text containsString:@"training benefit"] ||
                firstMatch(@"\\b\\d{1,2}:\\d{2}:\\d{2}\\b", text, 0) != nil ||
                firstMatch(@"\\b\\d{2,3}\\s*bpm\\b", text, 0) != nil ||
                firstMatch(@"\\b\\d{2,4}\\s*kcal\\b", text, 0) != nil) {
                continue;
            }
            double vertical = centerY(candidate) - centerY(label);
            if (vertical < -0.02 || vertical > 0.18) {
                continue;
            }
            double score = fabs(vertical) +
                fabs([candidate[@"x"] doubleValue] -
                     [label[@"x"] doubleValue]) * 0.5;
            if (score < selectedScore) {
                selected = candidate;
                selectedScore = score;
            }
        }
    }
    return selected == nil ? nil :
        [selected[@"text"] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSDictionary *inferZoneDurations(
    NSArray<NSDictionary *> *observations
) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *durations = [NSMutableArray array];
    for (NSDictionary *observation in observations) {
        if (firstMatch(
                @"\\b\\d{1,2}:\\d{2}:\\d{2}\\b",
                normalize(observation[@"text"]),
                0) != nil) {
            [durations addObject:observation];
        }
    }

    for (NSInteger zone = 1; zone <= 5; zone += 1) {
        NSString *zoneText = [NSString stringWithFormat:@"%ld", (long)zone];
        NSDictionary *selected = nil;
        double selectedScore = DBL_MAX;
        for (NSDictionary *label in observations) {
            if (![normalize(label[@"text"]) isEqualToString:zoneText] ||
                [label[@"confidence"] floatValue] < minimumConfidence ||
                centerX(label) > 0.20) {
                continue;
            }
            for (NSDictionary *candidate in durations) {
                double vertical = fabs(centerY(label) - centerY(candidate));
                double horizontal = centerX(candidate) - centerX(label);
                if (vertical > 0.035 ||
                    horizontal < 0.50 ||
                    centerX(candidate) < 0.75) {
                    continue;
                }
                double score = vertical +
                    (1.0 - centerX(candidate)) * 0.1;
                if (score < selectedScore) {
                    selected = candidate;
                    selectedScore = score;
                }
            }
        }
        if (selected != nil) {
            NSString *duration = firstMatch(
                @"\\b\\d{1,2}:\\d{2}:\\d{2}\\b",
                selected[@"text"],
                0);
            if (duration != nil) {
                result[zoneText] = duration;
            }
        }
    }
    return result;
}

static NSArray<NSDictionary *> *recognizeImage(
    NSURL *imageURL,
    NSError **error
) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = NO;

    NSData *imageData = [NSData dataWithContentsOfURL:imageURL
        options:0
        error:error];
    if (imageData == nil) {
        return nil;
    }
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc]
        initWithData:imageData
        options:@{}];
    if (![handler performRequests:@[request] error:error]) {
        return nil;
    }

    NSMutableArray<NSDictionary *> *observations = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        VNRecognizedText *candidate =
            [observation topCandidates:1].firstObject;
        if (candidate == nil) {
            continue;
        }
        CGRect box = observation.boundingBox;
        [observations addObject:@{
            @"text": candidate.string,
            @"confidence": @(candidate.confidence),
            @"x": @(box.origin.x),
            @"y": @(box.origin.y),
            @"width": @(box.size.width),
            @"height": @(box.size.height),
        }];
    }
    return observations;
}

static NSArray<NSDictionary *> *loadFixture(
    NSString *fixturePath,
    NSError **error
) {
    NSData *data = [NSData dataWithContentsOfFile:fixturePath
        options:0
        error:error];
    if (data == nil) {
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:data
        options:0
        error:error];
    if (![value isKindOfClass:NSArray.class]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"runningman.polar"
                code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    @"OCR fixture must be a JSON array"}];
        }
        return nil;
    }
    return value;
}

static NSNumber *plausibleNumber(
    NSString *value,
    NSInteger minimum,
    NSInteger maximum
) {
    if (value == nil) {
        return nil;
    }
    NSInteger number = value.integerValue;
    if (number < minimum || number > maximum) {
        return nil;
    }
    return @(number);
}

static NSDictionary *inferValues(
    NSArray<NSDictionary *> *observations
) {
    NSString *duration = matchedValue(
        observations,
        @[@[@"duration"]],
        @"\\b\\d{1,2}:\\d{2}:\\d{2}\\b",
        0);
    NSString *average = matchedValue(
        observations,
        @[@[@"hr", @"avg"], @[@"average", @"heart"], @[@"avg"]],
        @"\\b(\\d{2,3})\\s*bpm\\b",
        1);
    NSString *maximum = matchedValue(
        observations,
        @[@[@"hr", @"max"], @[@"maximum", @"heart"], @[@"max"]],
        @"\\b(\\d{2,3})\\s*bpm\\b",
        1);
    NSString *calories = matchedValue(
        observations,
        @[@[@"calories"]],
        @"\\b(\\d{2,4})\\s*kcal\\b",
        1);
    NSString *fatBurn = matchedValue(
        observations,
        @[@[@"fat", @"burn"]],
        @"\\b(\\d{1,3})\\s*%",
        1);

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (duration != nil) {
        result[@"duration"] = duration;
    }
    NSNumber *averageNumber = plausibleNumber(average, 30, 250);
    NSNumber *maximumNumber = plausibleNumber(maximum, 30, 260);
    NSNumber *calorieNumber = plausibleNumber(calories, 1, 10000);
    NSNumber *fatBurnNumber = plausibleNumber(fatBurn, 0, 100);
    if (averageNumber != nil) {
        result[@"average_heart_rate"] = averageNumber;
    }
    if (maximumNumber != nil) {
        result[@"maximum_heart_rate"] = maximumNumber;
    }
    if (calorieNumber != nil) {
        result[@"calories"] = calorieNumber;
    }
    if (fatBurnNumber != nil) {
        result[@"fat_burn_percent"] = fatBurnNumber;
    }
    NSString *trainingBenefit = inferTrainingBenefit(observations);
    if (trainingBenefit != nil) {
        result[@"training_benefit"] = trainingBenefit;
    }
    result[@"zone_durations"] = inferZoneDurations(observations);
    return result;
}

static void printUsage(void) {
    fprintf(stderr,
        "Usage: polar-ocr [--fixture OBSERVATIONS.json] IMAGE\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *fixturePath = nil;
        NSString *imagePath = nil;
        for (int index = 1; index < argc; index += 1) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if ([argument isEqualToString:@"--fixture"]) {
                index += 1;
                if (index >= argc) {
                    printUsage();
                    return 2;
                }
                fixturePath = [NSString stringWithUTF8String:argv[index]];
            } else if ([argument hasPrefix:@"-"] || imagePath != nil) {
                printUsage();
                return 2;
            } else {
                imagePath = argument;
            }
        }
        if (imagePath == nil) {
            printUsage();
            return 2;
        }

        NSError *error = nil;
        NSArray<NSDictionary *> *observations;
        if (fixturePath != nil) {
            observations = loadFixture(fixturePath, &error);
        } else {
            observations = recognizeImage(
                [NSURL fileURLWithPath:imagePath],
                &error);
        }
        if (observations == nil) {
            fprintf(stderr, "OCR failed: %s\n",
                error.localizedDescription.UTF8String);
            return 1;
        }
        if (observations.count == 0) {
            fprintf(stderr, "OCR found no text in the screenshot.\n");
            return 1;
        }

        NSDictionary *result = inferValues(observations);
        NSData *json = [NSJSONSerialization dataWithJSONObject:result
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
            error:&error];
        if (json == nil) {
            fprintf(stderr, "Could not encode OCR result: %s\n",
                error.localizedDescription.UTF8String);
            return 1;
        }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
