//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Derives `EntityRepresentable` from a struct's stored properties — the
/// macro counterpart of `scoutdb-codegen`, for entities modeled Swift-first.
public struct EntityMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw EntityMacroError("@Entity can only be attached to a struct")
        }
        let entity = explicitName(of: node) ?? snakeCase(structDecl.name.text)
        let fields = try storedFields(of: structDecl)
        guard fields.count > 0 else {
            throw EntityMacroError("@Entity needs at least one stored optional property")
        }

        let cases = fields.map { "        case \\\(type.trimmed).\($0.property): \"\($0.field)\"" }
        let decodes = fields.map { field in
            field.opaque
                ? "        \(field.property) = record.values[\"\(field.field)\"]"
                : "        \(field.property) = record[\"\(field.field)\"]"
        }
        let encodes = fields.map { field in
            field.opaque
                ? "        values[\"\(field.field)\"] = \(field.property)"
                : "        values[\"\(field.field)\"] = \(field.property)?.recordValue"
        }
        let conformance = protocols.isEmpty ? "" : ": EntityRepresentable"

        let source = """
            extension \(type.trimmed)\(conformance) {
                static var entityName: String { "\(entity)" }

                static func fieldName(for keyPath: PartialKeyPath<\(type.trimmed)>) -> String? {
                    switch keyPath {
            \(cases.joined(separator: "\n"))
                    default: nil
                    }
                }

                init(record: EntityRecord) {
            \(decodes.joined(separator: "\n"))
                }

                var recordValues: [String: RecordValue] {
                    var values: [String: RecordValue] = [:]
            \(encodes.joined(separator: "\n"))
                    return values
                }
            }
            """
        return [try ExtensionDeclSyntax(SyntaxNodeString(stringLiteral: source))]
    }

    private struct Field {
        let property: String
        let field: String
        let opaque: Bool
    }

    // The struct's stored properties, each mapped to its schema field: the
    // `@Field` override when given, the snake_cased property name otherwise.
    // `@Transient` and computed properties stay out; a participating property
    // must be optional — a record is free to miss any field.
    private static func storedFields(of declaration: StructDeclSyntax) throws -> [Field] {
        var fields: [Field] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
                !hasAttribute(variable, named: "Transient")
            else { continue }
            for binding in variable.bindings {
                guard binding.accessorBlock == nil, let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                guard let annotation = binding.typeAnnotation else {
                    throw EntityMacroError("@Entity property '\(name)' needs an explicit type annotation")
                }
                guard let wrapped = optionalBase(of: annotation.type) else {
                    throw EntityMacroError("@Entity property '\(name)' must be optional — a record is free to miss any field")
                }
                fields.append(
                    Field(
                        property: name,
                        field: fieldOverride(of: variable) ?? snakeCase(name),
                        opaque: wrapped.trimmedDescription == "RecordValue"
                    ))
            }
        }
        return fields
    }

    private static func optionalBase(of type: TypeSyntax) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return optional.wrappedType
        }
        if let generic = type.as(IdentifierTypeSyntax.self), generic.name.text == "Optional" {
            return generic.genericArgumentClause?.arguments.first?.argument.as(TypeSyntax.self)
        }
        return nil
    }

    private static func hasAttribute(_ variable: VariableDeclSyntax, named name: String) -> Bool {
        variable.attributes.contains { attribute in
            attribute.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == name
        }
    }

    private static func fieldOverride(of variable: VariableDeclSyntax) -> String? {
        for attribute in variable.attributes {
            guard let attribute = attribute.as(AttributeSyntax.self),
                attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Field"
            else { continue }
            return stringLiteral(of: attribute)
        }
        return nil
    }

    private static func explicitName(of node: AttributeSyntax) -> String? {
        stringLiteral(of: node)
    }

    private static func stringLiteral(of attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
            let literal = arguments.first?.expression.as(StringLiteralExprSyntax.self),
            let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else { return nil }
        return segment.content.text
    }

    private static func snakeCase(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase {
                if !result.isEmpty { result.append("_") }
                result.append(character.lowercased())
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// Marks the schema field behind a stored property.
///
/// Expansion-free: `@Entity` reads the annotation while deriving the field
/// map, so the peer expansion has nothing to add.
///
public struct FieldMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Excludes a stored property from the derived conformance.
public struct TransientMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

struct EntityMacroError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

@main
struct ScoutDBMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [EntityMacro.self, FieldMacro.self, TransientMacro.self]
}
