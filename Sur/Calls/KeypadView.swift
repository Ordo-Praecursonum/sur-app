//
//  KeypadView.swift
//  Sur
//
//  Standard phone keypad for dialing a raw number. On "call", hands off to
//  CallMethodPicker since a bare number has no known preferred method.
//

import SwiftUI

struct KeypadView: View {
    @State private var number = ""
    var onCall: (String) -> Void

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"],
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)

            Text(number.isEmpty ? " " : number)
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(height: 44)

            VStack(spacing: 16) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 24) {
                        ForEach(row, id: \.self) { digit in
                            digitButton(digit)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                callButton
                Spacer()
                if !number.isEmpty {
                    Button {
                        number.removeLast()
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title2)
                            .foregroundColor(.primary)
                            .frame(width: 64, height: 64)
                    }
                } else {
                    Color.clear.frame(width: 64, height: 64)
                }
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 20)
        }
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            number.append(digit)
        } label: {
            Text(digit)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 72, height: 72)
                .background(Theme.secondaryBackground)
                .foregroundColor(.primary)
                .clipShape(Circle())
        }
    }

    private var callButton: some View {
        Button {
            guard !number.isEmpty else { return }
            onCall(number)
        } label: {
            Image(systemName: "phone.fill")
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
                .background(number.isEmpty ? Color.gray : Color.green)
                .clipShape(Circle())
        }
        .disabled(number.isEmpty)
    }
}
