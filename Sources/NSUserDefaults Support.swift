//
//  NSUserDefaults Support.swift
//  GlueKit
//
//  Created by Károly Lőrentey on 2016-04-11.
//  Copyright © 2016 Károly Lőrentey. All rights reserved.
//

import Foundation

extension UserDefaults {
    public func updatable(for key: String) -> Updatable<Any?> {
        return self.updatable(forKeyPath: key)
    }

    public func updatableBool(for key: String, defaultValue: Bool = false) -> Updatable<Bool> {
        return self.updatable(forKeyPath: key)
            .map({ v in (v as? NSNumber)?.boolValue ?? defaultValue },
                 inverse: { v in v })
    }

    public func updatableInt(for key: String, defaultValue: Int = 0) -> Updatable<Int> {
        return self.updatable(forKeyPath: key)
            .map({ v in (v as? NSNumber)?.intValue ?? defaultValue },
                 inverse: { v in v })
    }

    public func updatableDouble(for key: String, defaultValue: Double = 0) -> Updatable<Double> {
        return self.updatable(forKeyPath: key)
            .map({ v in (v as? NSNumber)?.doubleValue ?? defaultValue },
                 inverse: { v in v })
    }

    public func updatableString(for key: String, defaultValue: String? = nil) -> Updatable<String?> {
        return self.updatable(forKeyPath: key)
            .map({ v in (v as? String) ?? defaultValue },
                 inverse: { v in v })
    }
}