//
//  NSError+init.swift
//  Code
//
//  Created by Ken Chung on 12/08/2023.
//

import Foundation

public extension NSError {
    convenience init(descriptionKey: String) {
        self.init(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: descriptionKey])
    }
}
