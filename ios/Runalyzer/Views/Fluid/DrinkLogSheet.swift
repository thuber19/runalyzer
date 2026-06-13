import SwiftUI

/// Quick drink logging sheet with favorites and category browsing.
struct DrinkLogSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var drinkTemplateStore: DrinkTemplateStore
    @EnvironmentObject var fluidIntakeProvider: FluidIntakeProvider

    @State private var selectedCategory: DrinkCategory?
    @State private var customVolume: String = ""
    @State private var showCustomDrink = false
    @State private var loggedToast: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Favorites
                    if !drinkTemplateStore.favorites.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("FAVORITES")
                                .font(.caption.bold())
                                .foregroundStyle(.gray)

                            LazyVGrid(columns: [
                                GridItem(.flexible()), GridItem(.flexible())
                            ], spacing: 10) {
                                ForEach(drinkTemplateStore.favorites) { template in
                                    quickLogButton(template)
                                }
                            }
                        }
                    }

                    // Category grid
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CATEGORIES")
                            .font(.caption.bold())
                            .foregroundStyle(.gray)

                        LazyVGrid(columns: [
                            GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible())
                        ], spacing: 10) {
                            ForEach(DrinkCategory.allCases, id: \.self) { category in
                                Button {
                                    withAnimation { selectedCategory = category }
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: category.icon)
                                            .font(.system(size: 22))
                                        Text(category.label)
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(selectedCategory == category ? .white : .gray)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(selectedCategory == category
                                                  ? Color.cyan.opacity(0.2) : Color.white.opacity(0.05))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Templates for selected category
                    if let category = selectedCategory {
                        let categoryTemplates = drinkTemplateStore.templates(for: category)
                        if !categoryTemplates.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(category.label.uppercased())
                                    .font(.caption.bold())
                                    .foregroundStyle(.gray)

                                ForEach(categoryTemplates) { template in
                                    templateRow(template)
                                }
                            }
                        }
                    }

                    // Add custom drink
                    Button {
                        showCustomDrink = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("Add Custom Drink")
                        }
                        .foregroundStyle(.cyan)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                    }
                }
                .padding()
            }
            .background(Color.appBackground)
            .navigationTitle("Log a Drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast = loggedToast {
                    Text(toast)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
            }
            .sheet(isPresented: $showCustomDrink) {
                CustomDrinkSheet()
            }
        }
    }

    // MARK: - Components

    private func quickLogButton(_ template: DrinkTemplate) -> some View {
        Button {
            logDrink(template)
        } label: {
            HStack {
                Image(systemName: template.icon)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading) {
                    Text(template.name)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Text("\(template.defaultVolumeMl) mL")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func templateRow(_ template: DrinkTemplate) -> some View {
        HStack {
            Image(systemName: template.icon)
                .foregroundStyle(.cyan)
                .frame(width: 30)

            VStack(alignment: .leading) {
                Text(template.name)
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text("\(template.defaultVolumeMl) mL")
                    if template.caffeineContentMg > 0 {
                        Text("\(template.caffeineContentMg) mg caffeine")
                    }
                    if template.alcoholPercent > 0 {
                        Text(String(format: "%.1f%% alc", template.alcoholPercent))
                    }
                }
                .font(.caption)
                .foregroundStyle(.gray)
            }

            Spacer()

            Button {
                drinkTemplateStore.toggleFavorite(template.id)
            } label: {
                Image(systemName: template.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(template.isFavorite ? .yellow : .gray)
            }

            Button {
                logDrink(template)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func logDrink(_ template: DrinkTemplate) {
        fluidIntakeProvider.logDrink(template: template)
        withAnimation(.spring(response: 0.3)) {
            loggedToast = "\(template.name) logged"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { loggedToast = nil }
        }
    }
}

// MARK: - Custom Drink Entry

struct CustomDrinkSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var drinkTemplateStore: DrinkTemplateStore

    @State private var name = ""
    @State private var category: DrinkCategory = .other
    @State private var volumeMl = "250"
    @State private var caffeineMg = ""
    @State private var alcoholPercent = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Drink Info") {
                    TextField("Name", text: $name)
                    Picker("Category", selection: $category) {
                        ForEach(DrinkCategory.allCases, id: \.self) { cat in
                            Text(cat.label).tag(cat)
                        }
                    }
                    TextField("Volume (mL)", text: $volumeMl)
                        .keyboardType(.numberPad)
                }

                Section("Content (optional)") {
                    TextField("Caffeine (mg)", text: $caffeineMg)
                        .keyboardType(.numberPad)
                    TextField("Alcohol (%)", text: $alcoholPercent)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Custom Drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let template = DrinkTemplate(
                            id: UUID(),
                            name: name,
                            category: category,
                            defaultVolumeMl: Int(volumeMl) ?? 250,
                            caffeineContentMg: Int(caffeineMg) ?? 0,
                            alcoholPercent: Double(alcoholPercent) ?? 0,
                            icon: category.icon,
                            isFavorite: false,
                            isCustom: true,
                            sortOrder: drinkTemplateStore.templates.count
                        )
                        drinkTemplateStore.save(template)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}
